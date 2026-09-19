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
    /// Horizontal flare width for the organic G1/G2 meniscus curve into the top bezel.
    public var flareX: CGFloat
    /// Vertical flare height for the organic G1/G2 meniscus curve from the top bezel.
    public var flareY: CGFloat

    public init(width: CGFloat, chinH: CGFloat, chinW: CGFloat,
                shoulder: CGFloat, bodyH: CGFloat, corner: CGFloat,
                flareX: CGFloat = 0, flareY: CGFloat = 0) {
        self.width = width
        self.chinH = chinH
        self.chinW = chinW
        self.shoulder = shoulder
        self.bodyH = bodyH
        self.corner = corner
        self.flareX = flareX
        self.flareY = flareY
    }

    public var height: CGFloat { chinH + shoulder + bodyH }

    /// Total visual width including both outward top bezel meniscus flares.
    public var totalWidth: CGFloat { width + 2 * flareX }

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
    public static let canvasSize = CGSize(width: 620, height: 594)

    public static func idle(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let w = layout.hasNotch ? max(184, layout.notchWidth + 8) : 160
        let chin = layout.hasNotch ? layout.topInset : 0
        let lip: CGFloat = layout.hasNotch ? 3 : 14
        let corner: CGFloat = layout.hasNotch ? 12 : 10
        let flareX: CGFloat = layout.hasNotch ? 18 : 14
        let flareY: CGFloat = layout.hasNotch ? 16 : 14
        return IslandMetrics(width: w, chinH: chin, chinW: w,
                             shoulder: 0, bodyH: lip, corner: corner,
                             flareX: flareX, flareY: flareY)
    }

    /// Slim "wings" compact: content flanks the housing. Used by data pill
    /// activities (timer, remote timer, transfer).
    public static func compactSlim(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        let w = layout.hasNotch ? max(440, layout.notchWidth + 260) : 440
        let lip: CGFloat = layout.hasNotch ? 10 : 42
        return IslandMetrics(width: w, chinH: chin, chinW: w,
                             shoulder: 0, bodyH: lip, corner: 21,
                             flareX: 22, flareY: 18)
    }

    /// Full "slab" compact: an organic capsule hanging from the top bezel.
    /// Media and external pills.
    public static func compactSlab(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        let w = layout.hasNotch ? max(490, layout.notchWidth + 290) : 490
        let lip: CGFloat = layout.hasNotch ? 10 : 42
        return IslandMetrics(width: w, chinH: chin, chinW: w,
                             shoulder: 0, bodyH: lip, corner: 21,
                             flareX: 22, flareY: 18)
    }

    /// Expanded: a fluid, Apple-grade living surface with utility panels.
    /// Perfectly proportioned under the notch with zero clipping.
    public static func expanded(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        let w = layout.hasNotch ? max(540, layout.notchWidth + 340) : 520
        let bodyH: CGFloat = layout.hasNotch ? 110 : 142
        return IslandMetrics(width: w,
                             chinH: chin, chinW: w,
                             shoulder: 0, bodyH: bodyH,
                             corner: 28,
                             flareX: 24, flareY: 20)
    }

    /// HUD capsule: a sleek capsule anchored to the top bezel for volume feedback.
    public static func hud(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        return IslandMetrics(width: 280, chinH: chin, chinW: 280,
                             shoulder: 0, bodyH: 22, corner: 22,
                             flareX: 18, flareY: 16)
    }

    /// Overture surfaces: melt beats collapse to the idle blend; teaching
    /// beats use the slab form.
    public static func overture(_ beat: Overture.Beat,
                                layout: NotchGeometry.Layout) -> IslandMetrics {
        switch beat {
        case .melt, .recede:
            return .idle(layout)
        case .greetings, .vocabTimer, .vocabFile, .vocabMedia:
            let chin = layout.hasNotch ? layout.topInset : 0
            let w = max(440, layout.notchWidth + 250)
            return IslandMetrics(width: w, chinH: chin, chinW: w,
                                 shoulder: 0, bodyH: 42, corner: 24,
                                 flareX: 22, flareY: 18)
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
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<
            AnimatablePair<CGFloat, CGFloat>,
            AnimatablePair<
                AnimatablePair<CGFloat, CGFloat>,
                AnimatablePair<CGFloat, CGFloat>
            >
        >
    >

    public var animatableData: AnimatableData {
        get {
            AnimatablePair(
                AnimatablePair(width, chinH),
                AnimatablePair(
                    AnimatablePair(chinW, shoulder),
                    AnimatablePair(
                        AnimatablePair(bodyH, corner),
                        AnimatablePair(flareX, flareY)
                    )
                )
            )
        }
        set {
            width = newValue.first.first
            chinH = newValue.first.second
            chinW = newValue.second.first.first
            shoulder = newValue.second.first.second
            bodyH = newValue.second.second.first.first
            corner = newValue.second.second.first.second
            flareX = newValue.second.second.second.first
            flareY = newValue.second.second.second.second
        }
    }

    // MARK: - Path (top-left origin, y down)

    /// The morph path inside a rect of (width × height), horizontally
    /// CENTERED in that rect (the window is the fixed canvas; a compact
    /// surface is narrower than the canvas and must hug the notch, which is
    /// screen-centered). Clockwise from the top-left at the bezel.
    public static func path(in rect: CGSize, m: IslandMetrics) -> Path {
        var p = Path()
        let dx = (rect.width - m.width) / 2
        let h = m.height
        let c = m.corner
        let fx = m.flareX
        let fy = m.flareY

        let left = dx
        let right = dx + m.width
        let topFlareLeft = left - fx
        let topFlareRight = right + fx

        // Organic G1/G2 meniscus: top flares outward into the top bezel
        if fx > 0 && fy > 0 {
            p.move(to: CGPoint(x: topFlareLeft, y: 0))
            p.addLine(to: CGPoint(x: topFlareRight, y: 0))

            // Right concave shoulder: horizontally tangent to top bezel, vertically tangent to flank
            p.addCurve(to: CGPoint(x: right, y: fy),
                       control1: CGPoint(x: right + fx * 0.45, y: 0),
                       control2: CGPoint(x: right, y: fy * 0.45))

            // Right flank down to bottom-right corner start
            p.addLine(to: CGPoint(x: right, y: max(fy, h - c)))

            // Bottom-right corner squircle
            p.addCurve(to: CGPoint(x: right - c, y: h),
                       control1: CGPoint(x: right, y: h - c * 0.45),
                       control2: CGPoint(x: right - c * 0.45, y: h))

            // Bottom edge across
            p.addLine(to: CGPoint(x: left + c, y: h))

            // Bottom-left corner squircle
            p.addCurve(to: CGPoint(x: left, y: max(fy, h - c)),
                       control1: CGPoint(x: left + c * 0.45, y: h),
                       control2: CGPoint(x: left, y: h - c * 0.45))

            // Left flank up
            p.addLine(to: CGPoint(x: left, y: fy))

            // Left concave shoulder: vertically tangent to flank, horizontally tangent to bezel
            p.addCurve(to: CGPoint(x: topFlareLeft, y: 0),
                       control1: CGPoint(x: left, y: fy * 0.45),
                       control2: CGPoint(x: topFlareLeft + fx * 0.45, y: 0))

            p.closeSubpath()
            return p
        }

        // Pure unified capsule (shoulder == 0 and chinW >= width):
        // Anchors directly to the top screen bezel, continuous squircle downward.
        if m.shoulder == 0 && m.chinW >= m.width {
            p.move(to: CGPoint(x: left, y: 0))
            p.addLine(to: CGPoint(x: right, y: 0))
            p.addLine(to: CGPoint(x: right, y: max(0, h - c)))
            p.addCurve(to: CGPoint(x: right - c, y: h),
                       control1: CGPoint(x: right, y: h - c * 0.45),
                       control2: CGPoint(x: right - c * 0.45, y: h))
            p.addLine(to: CGPoint(x: left + c, y: h))
            p.addCurve(to: CGPoint(x: left, y: max(0, h - c)),
                       control1: CGPoint(x: left + c * 0.45, y: h),
                       control2: CGPoint(x: left, y: h - c * 0.45))
            p.addLine(to: CGPoint(x: left, y: 0))
            p.closeSubpath()
            return p
        }

        // Stepped path with S-curves (used when synthetic tests provide shoulder > 0):
        let chinPad = dx + m.chinPad
        let chinRight = chinPad + m.chinW
        p.move(to: CGPoint(x: chinPad, y: 0))
        p.addLine(to: CGPoint(x: chinRight, y: 0))                       // housing top edge
        p.addLine(to: CGPoint(x: chinRight, y: m.chinH))                 // housing right edge
        if m.shoulder > 0 && right > chinRight {
            p.addCurve(to: CGPoint(x: right, y: m.chinH + m.shoulder),
                       control1: CGPoint(x: chinRight, y: m.chinH + m.shoulder * 0.5),
                       control2: CGPoint(x: right, y: m.chinH + m.shoulder * 0.5))
        } else {
            p.addLine(to: CGPoint(x: right, y: m.chinH + m.shoulder))
        }
        p.addLine(to: CGPoint(x: right, y: max(m.chinH + m.shoulder, h - c))) // right edge
        p.addCurve(to: CGPoint(x: right - c, y: h),
                   control1: CGPoint(x: right, y: h - c * 0.45),
                   control2: CGPoint(x: right - c * 0.45, y: h))
        p.addLine(to: CGPoint(x: left + c, y: h))                          // bottom edge
        p.addCurve(to: CGPoint(x: left, y: max(m.chinH + m.shoulder, h - c)),
                   control1: CGPoint(x: left + c * 0.45, y: h),
                   control2: CGPoint(x: left, y: h - c * 0.45))
        p.addLine(to: CGPoint(x: left, y: m.chinH + m.shoulder))           // left edge
        if m.shoulder > 0 && right > chinRight {
            p.addCurve(to: CGPoint(x: chinPad, y: m.chinH),
                       control1: CGPoint(x: left, y: m.chinH + m.shoulder * 0.5),
                       control2: CGPoint(x: chinPad, y: m.chinH + m.shoulder * 0.5))
        } else {
            p.addLine(to: CGPoint(x: chinPad, y: m.chinH))
        }
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
