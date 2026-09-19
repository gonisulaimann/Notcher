import AppKit
import SwiftUI

// MARK: - Bridges

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
    }
}

/// Invisible full-area drag catcher for file URLs (Finder drops).
struct DropCatcher: NSViewRepresentable {
    var onDrop: ([URL]) -> Void
    var onHighlight: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatchView()
        v.handler = onDrop
        v.highlight = onHighlight
        v.registerForDraggedTypes([.fileURL])
        return v
    }
    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let v = nsView as? CatchView else { return }
        v.handler = onDrop
        v.highlight = onHighlight
    }

    private final class CatchView: NSView {
        var handler: (([URL]) -> Void)?
        var highlight: ((Bool) -> Void)?
        override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation {
            shaping = true
            return .copy
        }
        override func draggingExited(_: NSDraggingInfo?) {
            shaping = false
        }
        override func draggingEnded(_: NSDraggingInfo) {
            shaping = false
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            shaping = false
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            handler?(urls)
            return true
        }
        /// While a drag hovers, DropCatcher highlights; hit delivery inside
        /// the shape is automatic via the container (no window flags needed).
        var shaping = false {
            didSet { highlight?(shaping) }
        }
    }
}

// MARK: - Surface

/// The single morphing surface: one animatable path carrying the vibrancy
/// material, the dark lens, the hairline stroke, the specular edge and the
/// ambient shadow. Split out of the root so the body's type-check stays
/// tractable; every state change is a spring interpolation of this shape.
struct SurfaceView: View {
    var metrics: IslandMetrics
    var strokeStyle: AnyShapeStyle
    var strokeWidth: CGFloat
    var expanded: Bool
    var dropTarget: Bool = false
    var pointerInside: Bool = false
    var isCharging: Bool = false
    var isLowBattery: Bool = false

    var body: some View {
        ZStack {
            // 1. Native Apple Vibrancy Glass (.ultraThinMaterial)
            Rectangle()
                .fill(.ultraThinMaterial)

            // 2. Hardware notch seamless black bleed: anchors to physical housing bezel
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.16),
                    .init(color: Color(red: 0.078, green: 0.078, blue: 0.102).opacity(0.85), location: 0.45), // #14141a
                    .init(color: Color(red: 0.031, green: 0.031, blue: 0.039).opacity(0.90), location: 1.0)  // #08080a
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 3. Drop target ambient illumination wash (subtle, non-jarring)
            if dropTarget {
                LinearGradient(
                    colors: [Color.orange.opacity(0.20), Color.orange.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // 4. Charging surge dynamic energy wash (subtle Apple mint, strictly no jarring neon)
            if isCharging {
                LinearGradient(
                    colors: [Color.green.opacity(0.12), Color.teal.opacity(0.05), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }

            // 5. Low battery warning subtle breath wash
            if isLowBattery {
                LinearGradient(
                    colors: [Color.red.opacity(0.14), Color.orange.opacity(0.04), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
        }
        .frame(width: metrics.totalWidth, height: metrics.height, alignment: .top)
        .mask(MorphShape(m: metrics))
        .overlay(
            // 6. Subtle inner borders & dynamic desktop-adaptive specular highlights:
            // Top edge is Color.clear to fuse with the hardware notch without seams or dividing borders.
            // Rim has subtle 12% white opacity inner border with hover specular catch.
            MorphShape(m: metrics)
                .stroke(
                    dropTarget
                        ? AnyShapeStyle(Color.orange.opacity(0.75))
                        : AnyShapeStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .clear, location: 0.18),
                                    .init(color: Color.white.opacity(0.04), location: 0.40),
                                    .init(color: Color.white.opacity(pointerInside ? 0.20 : 0.12), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        ),
                    lineWidth: dropTarget ? 1.5 : 0.75
                )
                .allowsHitTesting(false)
        )
        // 7. Soft dual ambient shadows: contact shadow + soft ambient spread
        .shadow(color: Color.black.opacity(0.32), radius: 4, x: 0, y: 2)
        .shadow(color: Color.black.opacity(0.20), radius: 24, x: 0, y: 10)
    }
}

// MARK: - Root

public struct IslandRootView: View {
    @ObservedObject var island: IslandState
    @ObservedObject var timer: TimerEngine
    @ObservedObject var media: MediaEngine
    @ObservedObject var power: PowerEngine
    @ObservedObject var harbor: HarborStore
    @ObservedObject var link: LinkHost
    @ObservedObject var center: ExternalCenter
    @ObservedObject var clipboard: ClipboardEngine
    @ObservedObject var hudEngine: HudEngine
    @ObservedObject var privacy: PrivacyWatch
    var layout: NotchGeometry.Layout
    var layoutProvider: (() -> NotchGeometry.Layout)?
    var onDropFiles: ([URL]) -> Void
    var onInteract: () -> Void

    public init(island: IslandState, timer: TimerEngine, media: MediaEngine,
                power: PowerEngine, harbor: HarborStore, link: LinkHost,
                center: ExternalCenter, clipboard: ClipboardEngine,
                hudEngine: HudEngine, privacy: PrivacyWatch,
                layout: NotchGeometry.Layout,
                layoutProvider: (() -> NotchGeometry.Layout)? = nil,
                onDropFiles: @escaping ([URL]) -> Void,
                onInteract: @escaping () -> Void = {}) {
        self.island = island
        self.timer = timer
        self.media = media
        self.power = power
        self.harbor = harbor
        self.link = link
        self.center = center
        self.clipboard = clipboard
        self.hudEngine = hudEngine
        self.privacy = privacy
        self.layout = layout
        self.layoutProvider = layoutProvider
        self.onDropFiles = onDropFiles
        self.onInteract = onInteract
    }

    private var currentLayout: NotchGeometry.Layout {
        layoutProvider?() ?? layout
    }

    /// The island's single source of shape truth, recomputed on every state
    /// change; SwiftUI animates the MorphShape between them (one continuous
    /// spring interpolation — the whole transition).
    private var metrics: IslandMetrics {
        island.surfaceMetrics(layout: currentLayout)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            surfaceLayer
            contentLayer
        }
        .frame(width: metrics.totalWidth, height: metrics.height, alignment: .top)
        .contentShape(MorphShape(m: metrics))
        .onHover { hovering in
            island.pointerInside = hovering
            if hovering { island.hoverEntered() } else { island.hoverExited() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(island.contentAnimation, value: island.mode)
        .animation(island.contentAnimation, value: island.activity)
        .animation(island.contentAnimation, value: island.flash?.id)
        .animation(island.hudAnimation, value: island.hud)
        .environment(\.colorScheme, .dark)
        .background(DropCatcher(onDrop: onDropFiles, onHighlight: { island.setDropTarget($0) }))
    }

    private var surfaceLayer: some View {
        SurfaceView(metrics: metrics,
                    strokeStyle: island.dropTarget
                        ? AnyShapeStyle(Color.orange.opacity(0.92))
                        : AnyShapeStyle(Color.white.opacity(island.pointerInside ? 0.24 : 0.16)),
                    strokeWidth: island.dropTarget ? 2 : 1,
                    expanded: island.mode == .expanded,
                    dropTarget: island.dropTarget,
                    pointerInside: island.pointerInside,
                    isCharging: power.charging,
                    isLowBattery: (power.percent ?? 100) < 20 && !power.charging)
            .frame(width: metrics.totalWidth, height: metrics.height, alignment: .top)
            .animation(island.motionAnimation, value: metrics)
    }

    private var contentLayer: some View {
        content
            .frame(width: metrics.width, height: metrics.height, alignment: .top)
            .frame(width: metrics.totalWidth, height: metrics.height, alignment: .center)
            .mask(MorphShape(m: metrics))
            .animation(island.motionAnimation, value: metrics)
    }

    @ViewBuilder
    private var content: some View {
        if let beat = island.overtureBeat {
            OvertureBeatContent(beat: beat)
                .frame(width: metrics.width, height: metrics.bodyH)
                .padding(.top, metrics.contentTop)
        } else if island.mode == .hud, let hud = island.hud {
            HudView(content: hud)
                .frame(width: metrics.width, height: metrics.bodyH)
                .padding(.top, metrics.contentTop)
        } else if island.mode == .expanded {
            ExpandedView(island: island, timer: timer, media: media, power: power,
                         harbor: harbor, link: link, center: center,
                         clipboard: clipboard, hudEngine: hudEngine,
                         privacy: privacy, onInteract: onInteract)
                .frame(width: metrics.width, height: metrics.bodyH, alignment: .top)
                .padding(.top, metrics.contentTop)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity
                ))
        } else {
            compactContent
                .frame(width: metrics.width, height: metrics.height, alignment: .center)
                .transition(.opacity)
        }
        // Privacy sensors always visible when active.
        if privacy.privacyActive {
            HStack(spacing: 5) {
                if privacy.cameraActive {
                    Circle().fill(Color(red: 0.35, green: 0.82, blue: 1.0))
                        .frame(width: 5, height: 5)
                }
                if privacy.micActive {
                    Circle().fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .offset(y: metrics.contentTop == 0 ? 20 : 11)
            .animation(island.hudAnimation, value: privacy.privacyActive)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        let notchW = currentLayout.hasNotch ? currentLayout.notchWidth : 0
        if let flash = island.flash {
            if flash.icon == "bolt.fill" {
                ChargingFlashContent(text: flash.text, percent: power.percent, chinW: notchW)
            } else {
                FlashContent(icon: flash.icon, text: flash.text, chinW: notchW)
            }
        } else {
            switch island.activity {
            case .liveActivity:
                if let live = link.liveActivity {
                    LiveActivitySlabContent(live: live, chinW: notchW)
                } else {
                    FlashContent(icon: "sparkles", text: "Live Activity", chinW: notchW)
                }
            case .timer:
                TimerWingsContent(timer: timer, chinW: notchW)
            case .transfer:
                TransferWingsContent(link: link, chinW: notchW)
            case .remoteTimer:
                if let r = link.remoteTimer {
                    RemoteTimerPillContent(peer: r.peer, remaining: r.remaining,
                                           total: r.total, updatedAt: r.updatedAt, chinW: notchW)
                } else {
                    FlashContent(icon: "timer", text: "iPhone timer ended", chinW: notchW)
                }
            case .media:
                if media.appName != nil {
                    MediaSlabContent(media: media, chinW: notchW)
                } else {
                    FlashContent(icon: "music.note", text: "Nothing playing", chinW: notchW)
                }
            case .external:
                if let e = center.visible {
                    ExternalSlabContent(icon: e.icon, title: e.title, subtitle: e.subtitle,
                                        progress: e.progress, source: e.source, chinW: notchW)
                } else {
                    FlashContent(icon: "app.badge", text: "Waterline clear", chinW: notchW)
                }
            case .none:
                IdleHintContent(chinW: notchW)
            }
        }
    }
}

// MARK: - Compact content (notch-safe geometry)

/// Live equalizer animation that reacts to playback state.
public struct WaveformIndicator: View {
    public var isPlaying: Bool
    public var color: Color = IslandPalette.media

    public init(isPlaying: Bool, color: Color = IslandPalette.media) {
        self.isPlaying = isPlaying
        self.color = color
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isPlaying)) { timeline in
            let t = isPlaying ? timeline.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .bottom, spacing: 2) {
                bar(height: isPlaying ? 4 + 7 * abs(sin(t * 7.0)) : 3)
                bar(height: isPlaying ? 5 + 8 * abs(sin(t * 9.5 + 1.2)) : 5)
                bar(height: isPlaying ? 3 + 9 * abs(sin(t * 6.2 + 2.5)) : 3)
            }
            .frame(width: 12, height: 14, alignment: .bottom)
        }
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color)
            .frame(width: 2, height: height)
    }
}

/// Symmetrical Wings Row: leading and trailing rails flanking the camera housing.
/// Content renders centered across the full pill height.
struct WingsRow<Leading: View, Trailing: View>: View {
    var chinW: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { leading }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if chinW > 0 {
                Spacer()
                    .frame(width: chinW)
            } else {
                Spacer(minLength: 16)
            }

            HStack(spacing: 6) { trailing }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

struct ChargingFlashContent: View {
    var text: String
    var percent: Double?
    var chinW: CGFloat = 0

    var body: some View {
        WingsRow(chinW: chinW) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.20, green: 0.84, blue: 0.60))
                Text(percent.map { "\(Int($0))%" } ?? (text.isEmpty ? "Charging" : text))
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(red: 0.20, green: 0.84, blue: 0.60))
            }
        } trailing: {
            EmptyView()
        }
    }
}

public struct LiveActivitySlabContent: View {
    public var live: LinkHost.MirroredLiveActivity
    var chinW: CGFloat = 0

    public init(live: LinkHost.MirroredLiveActivity, chinW: CGFloat = 0) {
        self.live = live
        self.chinW = chinW
    }

    public var body: some View {
        WingsRow(chinW: chinW) {
            HStack(spacing: 6) {
                Image(systemName: live.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(live.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        } trailing: {
            if let trail = live.trailingText, !trail.isEmpty {
                Text(trail)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else if let sub = live.subtitle {
                Text(sub)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
    }

    private var iconColor: Color {
        switch live.type {
        case "delivery": return Color.orange
        case "ride": return Color.cyan
        case "flight": return Color.blue
        case "workout": return Color.green
        default: return IslandPalette.external
        }
    }
}

struct FlashContent: View {
    var icon: String
    var text: String
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } trailing: {
            EmptyView()
        }
    }
}

struct TimerWingsContent: View {
    @ObservedObject var timer: TimerEngine
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.20))
                        .frame(width: 22, height: 22)
                    Circle()
                        .trim(from: 0, to: timer.progress)
                        .stroke(Color(red: 0.96, green: 0.62, blue: 0.04), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                }
                Text(TimerFormat.string(timer.remaining))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        } trailing: {
            Button(action: {
                if timer.state == .paused { timer.resume() }
                else { timer.pause() }
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 22, height: 22)
                    Image(systemName: timer.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(timer.state == .paused ? "Resume" : "Pause")
        }
    }
}

struct TransferWingsContent: View {
    @ObservedObject var link: LinkHost
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue.opacity(0.30))
                        .frame(width: 18, height: 18)
                    Image(systemName: "doc.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                }
                Text(link.receiving.map { "Receiving \($0.fileName)" } ?? "Receiving 3 files")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } trailing: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                    .frame(width: 16, height: 16)
                Circle()
                    .trim(from: 0, to: link.receiving.map { $0.total > 0 ? Double($0.got) / Double($0.total) : 0.65 } ?? 0.65)
                    .stroke(Color(red: 0.35, green: 0.65, blue: 1.0), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

struct IdleHintContent: View {
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            Spacer(minLength: 0)
        } trailing: {
            Spacer(minLength: 0)
        }
    }
}

/// Media slab: minimal, un-cluttered collapsed single-activity context flanking the notch.
/// Leading: album artwork (26x26, 6pt squircle) + Title and Artist in SF Pro Rounded.
/// Center: physical camera housing band.
/// Trailing: live audio waveform equalizer + circular play/pause button.
public struct MediaSlabContent: View {
    @ObservedObject var media: MediaEngine
    var chinW: CGFloat = 0

    public init(media: MediaEngine, chinW: CGFloat = 0) {
        self.media = media
        self.chinW = chinW
    }

    public var body: some View {
        WingsRow(chinW: chinW) {
            HStack(spacing: 8) {
                ArtworkView(url: media.artworkURL, data: media.artworkData, cornerRadius: 6)
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.40), radius: 3, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title ?? "Not Playing")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(media.artist ?? (media.appName ?? "Music"))
                        .font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        } trailing: {
            HStack(spacing: 10) {
                WaveformIndicator(isPlaying: media.playing, color: Color(red: 0.22, green: 0.74, blue: 0.98))

                Button(action: { media.playPause() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 22, height: 22)
                        Image(systemName: media.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(media.playing ? "Pause" : "Play")
            }
        }
    }
}

/// External (waterline) slab: mirrors the media slab's language flanking the notch.
public struct ExternalSlabContent: View {
    public var icon: String
    public var title: String
    public var subtitle: String?
    public var progress: Double?
    public var source: String
    var chinW: CGFloat = 0

    public init(icon: String, title: String, subtitle: String? = nil, progress: Double? = nil, source: String = "", chinW: CGFloat = 0) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.source = source
        self.chinW = chinW
    }

    public var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.external)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        } trailing: {
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            } else if !source.isEmpty {
                Text(source)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(IslandPalette.external.opacity(0.85))
            }
        }
    }
}

/// Remote timer keeps the wings form (data pill).
public struct RemoteTimerPillContent: View {
    public var peer: String
    public var remaining: Double
    public var total: Double
    public var updatedAt: Date
    public var chinW: CGFloat

    public init(peer: String, remaining: Double, total: Double, updatedAt: Date,
                chinW: CGFloat = 0) {
        self.peer = peer
        self.remaining = remaining
        self.total = total
        self.updatedAt = updatedAt
        self.chinW = chinW
    }

    public var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.timer)
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(TimerFormat.string(liveRemaining(base: remaining,
                                                      updatedAt: updatedAt,
                                                      now: context.date)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        } trailing: {
            Text(peer)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - HUD capsule

public struct HudView: View {
    public var content: IslandState.HudContent

    public init(content: IslandState.HudContent) { self.content = content }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isMuted ? .white.opacity(0.40) : .white.opacity(0.95))
                .frame(width: 22)
            Meter(value: content.value,
                  color: isMuted ? .white.opacity(0.35) : .white,
                  height: 6)
                .frame(maxWidth: .infinity)
            Text("\(Int((content.value * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityName) \(Int(content.value * 100)) percent")
    }

    private var isMuted: Bool {
        if case .volume(let muted) = content.kind { return muted }
        return false
    }

    private var icon: String {
        switch content.kind {
        case .volume(let muted): return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        }
    }

    private var accessibilityName: String {
        switch content.kind {
        case .volume: return "Volume"
        case .brightness: return "Brightness"
        }
    }
}

// MARK: - Expanded tray

struct ExpandedView: View {
    @ObservedObject var island: IslandState
    @ObservedObject var timer: TimerEngine
    @ObservedObject var media: MediaEngine
    @ObservedObject var power: PowerEngine
    @ObservedObject var harbor: HarborStore
    @ObservedObject var link: LinkHost
    @ObservedObject var center: ExternalCenter
    @ObservedObject var clipboard: ClipboardEngine
    @ObservedObject var hudEngine: HudEngine
    @ObservedObject var privacy: PrivacyWatch
    var onInteract: () -> Void

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case active = "Active"
        case clipboard = "Clipboard"
        case toggles = "Toggles"
        case shortcuts = "Shortcuts"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .active: return "sparkles"
            case .clipboard: return "doc.on.clipboard"
            case .toggles: return "switch.2"
            case .shortcuts: return "command"
            }
        }
    }

    var initialTab: Tab = .active
    @State private var selectedTab: Tab

    init(island: IslandState, timer: TimerEngine, media: MediaEngine,
         power: PowerEngine, harbor: HarborStore, link: LinkHost,
         center: ExternalCenter, clipboard: ClipboardEngine,
         hudEngine: HudEngine, privacy: PrivacyWatch,
         initialTab: Tab = .active,
         onInteract: @escaping () -> Void) {
        self.island = island
        self.timer = timer
        self.media = media
        self.power = power
        self.harbor = harbor
        self.link = link
        self.center = center
        self.clipboard = clipboard
        self.hudEngine = hudEngine
        self.privacy = privacy
        self.initialTab = initialTab
        self._selectedTab = State(initialValue: initialTab)
        self.onInteract = onInteract
    }

    @State private var showUtilities = false

    var body: some View {
        Group {
            if !showUtilities && selectedTab == .active {
                activePanel
            } else {
                VStack(spacing: 6) {
                    header

                    Group {
                        switch selectedTab {
                        case .active:
                            activePanel
                        case .clipboard:
                            ClipboardPanel(clipboard: clipboard)
                        case .toggles:
                            QuickTogglesPanel(hudEngine: hudEngine, clipboard: clipboard)
                        case .shortcuts:
                            SystemShortcutsPanel()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .onTapGesture { onInteract() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var activePanel: some View {
        if let live = link.liveActivity {
            LiveActivityExpanded(live: live)
        } else if media.appName != nil {
            NowPlayingExpanded(media: media, onMore: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    showUtilities.toggle()
                }
            })
        } else if timer.isActive || timer.state == .done {
            TimerExpanded(timer: timer, onMore: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    showUtilities.toggle()
                }
            })
        } else if !harbor.items.isEmpty {
            HarborExpanded(harbor: harbor)
        } else {
            StandbyExpanded(harbor: harbor, timer: timer, onMore: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    showUtilities.toggle()
                }
            })
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showUtilities = false
                    selectedTab = .active
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                    Text("Player")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(IslandPalette.external)
            }
            .buttonStyle(PressableButtonStyle())

            Spacer()

            // Dynamic segmented tab pill switcher
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    Button(action: {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            selectedTab = tab
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 9, weight: .semibold))
                            if selectedTab == tab {
                                Text(tab.rawValue)
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .fixedSize()
                            }
                        }
                        .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.50))
                        .padding(.horizontal, selectedTab == tab ? 7 : 5)
                        .padding(.vertical, 3.5)
                        .background(
                            selectedTab == tab
                                ? Color.white.opacity(0.18)
                                : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: Capsule())

            Spacer()

            Button(action: { island.collapse() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.60))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.05), in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Collapse island")
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

// MARK: - Utility Panels

struct LiveActivityExpanded: View {
    var live: LinkHost.MirroredLiveActivity

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [iconColor.opacity(0.35), iconColor.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: live.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(live.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        if let lead = live.leadingText, !lead.isEmpty {
                            Text(lead)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(iconColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(iconColor.opacity(0.15), in: Capsule())
                        }
                    }
                    if let sub = live.subtitle {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let trail = live.trailingText, !trail.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(trail)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("STATUS")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.40))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // Milestone / Progress Track
            if let p = live.progress {
                VStack(spacing: 4) {
                    Meter(value: p, color: iconColor, height: 5)
                    HStack {
                        Text(live.leadingText ?? "Started")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Text(live.trailingText ?? "Arriving")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch live.type {
        case "delivery": return Color.orange
        case "ride": return Color.cyan
        case "flight": return Color.blue
        case "workout": return Color.green
        default: return IslandPalette.external
        }
    }
}

struct ClipboardPanel: View {
    @ObservedObject var clipboard: ClipboardEngine
    @State private var copiedId: UUID?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("CLIPBOARD HISTORY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.50))
                    .tracking(0.5)
                if !clipboard.entries.isEmpty {
                    Text("\(clipboard.entries.count)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                Spacer()
                if !clipboard.entries.isEmpty {
                    Button("Clear") {
                        clipboard.clear()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                    .buttonStyle(PressableButtonStyle())
                }
            }

            if !clipboard.enabled {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(IslandPalette.clipboard)
                    Text("Clipboard history is opt-in for privacy")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("History is stored in volatile memory only and never saved to disk.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                    Button("Enable Clipboard History") {
                        clipboard.setEnabled(true)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.white, in: Capsule())
                    .buttonStyle(PressableButtonStyle())
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 10)
            } else if clipboard.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No copied text yet")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Text("Copy text anywhere on your Mac to access it here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 14)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 5) {
                        ForEach(clipboard.entries) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 10))
                                    .foregroundStyle(IslandPalette.clipboard)
                                    .frame(width: 16)

                                Text(entry.preview)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 4)

                                Button(action: {
                                    clipboard.copy(entry)
                                    copiedId = entry.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        if copiedId == entry.id { copiedId = nil }
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        if copiedId == entry.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.green)
                                            Text("Copied")
                                                .font(.system(size: 9.5, weight: .bold))
                                                .foregroundStyle(.green)
                                        } else {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 8.5, weight: .medium))
                                            Text("Copy")
                                                .font(.system(size: 9.5, weight: .medium))
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(copiedId == entry.id ? 0.16 : 0.08), in: Capsule())
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onDrag { NSItemProvider(object: NSString(string: entry.text)) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 140)
            }
        }
    }
}

struct QuickTogglesPanel: View {
    @ObservedObject var hudEngine: HudEngine
    @ObservedObject var clipboard: ClipboardEngine

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("QUICK TOGGLES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.50))
                    .tracking(0.5)
                Spacer()
            }

            VStack(spacing: 6) {
                toggleRow(
                    icon: "speaker.wave.2.fill",
                    color: Color.blue,
                    title: "Volume HUD at Notch",
                    subtitle: "Fluid volume bar below camera housing",
                    isOn: Binding(
                        get: { hudEngine.enabled },
                        set: { hudEngine.setEnabled($0) }
                    )
                )

                toggleRow(
                    icon: "doc.on.clipboard.fill",
                    color: IslandPalette.clipboard,
                    title: "Clipboard History",
                    subtitle: "Fast in-memory snippet shelf",
                    isOn: Binding(
                        get: { clipboard.enabled },
                        set: { clipboard.setEnabled($0) }
                    )
                )

                toggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    color: Color.orange,
                    title: "Open at Login",
                    subtitle: "Launch Notcher automatically",
                    isOn: Binding(
                        get: { LaunchAtLogin.enabled },
                        set: { try? LaunchAtLogin.set($0) }
                    )
                )

                audioOutputRow
            }
        }
    }

    private var audioOutputRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.purple.opacity(0.20))
                Image(systemName: "airpodspro")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.purple)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("Audio Output")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("System Speakers / AirPods")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button(action: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                    Text("Switch")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.10), in: Capsule())
                .foregroundStyle(.white.opacity(0.90))
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toggleRow(icon: String, color: Color, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.20))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.50))
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(color)
                .scaleEffect(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct SystemShortcutsPanel: View {
    @State private var feedbackText: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SYSTEM SHORTCUTS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.50))
                    .tracking(0.5)
                Spacer()
                if let fb = feedbackText {
                    Text(fb)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                shortcutTile(icon: "lock.fill", color: .red, title: "Lock Screen", subtitle: "Instant lock") {
                    feedback("Locked screen")
                    lockScreen()
                }

                shortcutTile(icon: "moon.fill", color: .purple, title: "Sleep Display", subtitle: "Turn off screen") {
                    feedback("Display sleep")
                    sleepDisplay()
                }

                shortcutTile(icon: "camera.viewfinder", color: .cyan, title: "Screenshot Area", subtitle: "Copy to pasteboard") {
                    feedback("Crosshair ready")
                    screenshotArea()
                }

                shortcutTile(icon: "apple.terminal", color: .green, title: "Terminal", subtitle: "Open shell") {
                    feedback("Opening Terminal")
                    openTerminal()
                }
            }
        }
    }

    private func feedback(_ text: String) {
        feedbackText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if feedbackText == text { feedbackText = nil }
        }
    }

    private func shortcutTile(icon: String, color: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.20))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.50))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func lockScreen() {
        let lib = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        if let sym = dlsym(lib, "SACLockScreenImmediate") {
            let lock = unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
            lock()
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        }
    }

    private func sleepDisplay() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    private func screenshotArea() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-c"]
        try? p.run()
    }

    private func openTerminal() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Contextual Hero Surfaces

struct NowPlayingExpanded: View {
    @ObservedObject var media: MediaEngine
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left: Large Album Artwork (58x58 with smooth 12pt corner radius)
            ArtworkView(url: media.artworkURL, data: media.artworkData, cornerRadius: 12)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)

            // Right: Living Info & Controls Stack
            VStack(alignment: .leading, spacing: 10) {
                // Top Row: Stacked (Title + Artist) on left, Spacer, Waveform + Controls on right
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title ?? "Not Playing")
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(media.artist ?? (media.appName ?? "Music"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    WaveformIndicator(isPlaying: media.playing, color: Color(red: 0.22, green: 0.74, blue: 0.98))
                        .padding(.trailing, 2)

                    // Transport Cluster
                    HStack(spacing: 8) {
                        Button(action: { media.previous() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.80))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Previous")

                        Button(action: { media.playPause() }) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(width: 30, height: 30)
                                Image(systemName: media.playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(media.playing ? "Pause" : "Play")

                        Button(action: { media.next() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.80))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Next")

                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                        }) {
                            Image(systemName: "airplayaudio")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.60))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("AirPlay")

                        Button(action: { onMore?() }) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.60))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("More")
                    }
                }

                // Bottom Row: Scrubber Bar with Timestamps (Position on left, Remaining on right)
                HStack(spacing: 8) {
                    Text(media.positionText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.60))

                    Meter(value: media.progressFraction,
                          color: Color(red: 0.22, green: 0.74, blue: 0.98),
                          height: 3)
                        .frame(maxWidth: .infinity)

                    Text(remainingOrDurationText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.60))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var remainingOrDurationText: String {
        if let dur = media.duration, dur > media.livePosition, media.livePosition > 0 {
            let rem = dur - media.livePosition
            let m = Int(rem) / 60
            let s = Int(rem) % 60
            return String(format: "-%d:%02d", m, s)
        }
        return media.durationText
    }
}

struct TimerExpanded: View {
    @ObservedObject var timer: TimerEngine
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left: Amber Circular Timer Badge
            ZStack {
                Circle()
                    .fill(Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.20))
                    .frame(width: 58, height: 58)
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                    .frame(width: 50, height: 50)
                Circle()
                    .trim(from: 0, to: timer.progress)
                    .stroke(Color(red: 0.96, green: 0.62, blue: 0.04), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "timer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
            }
            .frame(width: 58, height: 58)

            // Right: Living Info & Controls Stack
            VStack(alignment: .leading, spacing: 4) {
                // Top Row: Label + Action Buttons
                HStack(spacing: 8) {
                    Text(timer.label.isEmpty ? "Focus Timer" : timer.label)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        Button("+1m") { timer.addTime(seconds: 60) }
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .buttonStyle(PressableButtonStyle())

                        Button("+5m") { timer.addTime(seconds: 300) }
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .buttonStyle(PressableButtonStyle())

                        Button(action: {
                            if timer.state == .running { timer.pause() }
                            else { timer.resume() }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(width: 28, height: 28)
                                Image(systemName: timer.state == .paused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button(action: { timer.cancel() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button(action: { onMore?() }) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.60))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }

                // Middle Row: Big Digits
                Text(TimerFormat.string(timer.remaining))
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)

                // Bottom Row: Progress meter
                HStack(spacing: 8) {
                    Meter(value: timer.progress,
                          color: Color(red: 0.96, green: 0.62, blue: 0.04),
                          height: 3)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct HarborExpanded: View {
    @ObservedObject var harbor: HarborStore

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("HARBOR SHELF")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.5)
                Spacer()
                Text("\(harbor.count) parked · drag out to use")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.40))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(harbor.items) { item in
                        HarborItemTile(item: item, harbor: harbor)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct StandbyExpanded: View {
    @ObservedObject var harbor: HarborStore
    @ObservedObject var timer: TimerEngine
    var onMore: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left: Refined Notcher icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.25, green: 0.45, blue: 0.95), Color(red: 0.60, green: 0.25, blue: 0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: "water.waves")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)

            // Right: Living Info & Controls Stack
            VStack(alignment: .leading, spacing: 4) {
                // Top Row: Title + Status + Controls
                HStack(spacing: 8) {
                    Text("Notcher")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Ready")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.20, green: 0.84, blue: 0.60))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.20, green: 0.84, blue: 0.60).opacity(0.15), in: Capsule())

                    Spacer(minLength: 4)

                    Button(action: { onMore?() }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.60))
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Utilities")
                }

                // Middle Row: Subtitle
                Text("MacBook Dynamic Island · Drop files or hover")
                    .font(.system(size: 11.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)

                // Bottom Row: Quick Focus Presets
                HStack(spacing: 8) {
                    Text("TIMER")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                        .tracking(0.5)

                    Button("25m Focus") { timer.start(seconds: 25 * 60, label: "Focus") }
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.96, green: 0.62, blue: 0.04).opacity(0.25), in: Capsule())
                        .buttonStyle(PressableButtonStyle())

                    Button("15m") { timer.start(seconds: 15 * 60, label: "Short") }
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .buttonStyle(PressableButtonStyle())

                    Button("5m") { timer.start(seconds: 5 * 60, label: "Break") }
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .buttonStyle(PressableButtonStyle())
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Tray sections

/// Hero media card: artwork, title/artist, live waveform, transport, progress scrubber, AirPlay.
struct NowPlayingSection: View {
    @ObservedObject var media: MediaEngine
    @State private var isStarred = false

    var body: some View {
        SectionCard(title: "Now Playing", system: "music.note") {
            if media.appName != nil {
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        ArtworkView(url: media.artworkURL, data: media.artworkData)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(media.title ?? "Unknown track")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .tracking(-0.3)
                                    .lineLimit(1)
                                if media.playing {
                                    WaveformIndicator(isPlaying: true, color: IslandPalette.media)
                                }
                            }
                            Text([media.artist, media.appName].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        Spacer()
                    }

                    // Interactive Scrub Bar
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Text(media.positionText)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.50))
                                .frame(width: 36, alignment: .leading)
                            Meter(value: media.progressFraction, color: IslandPalette.media, height: 5)
                            Text(media.durationText)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.50))
                                .frame(width: 36, alignment: .trailing)
                        }
                    }

                    // Transport Bar
                    HStack(spacing: 20) {
                        Button(action: { isStarred.toggle() }) {
                            Image(systemName: isStarred ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isStarred ? Color.yellow : Color.white.opacity(0.65))
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Favorite")

                        Spacer()

                        TrayIconButton(system: "backward.fill", label: "Previous track", action: media.previous)

                        TrayIconButton(system: media.playing ? "pause.fill" : "play.fill",
                                       label: media.playing ? "Pause" : "Play",
                                       prominent: true,
                                       size: 36,
                                       action: media.playPause)

                        TrayIconButton(system: "forward.fill", label: "Next track", action: media.next)

                        Spacer()

                        Button(action: {}) {
                            Image(systemName: "airplayaudio")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.65))
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("AirPlay output")
                    }
                    .padding(.horizontal, 4)
                }
            } else {
                Text("Nothing playing in Music or Spotify.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

struct TimerSection: View {
    @ObservedObject var timer: TimerEngine

    var body: some View {
        SectionCard(title: "Timer", system: "timer") {
            if timer.isActive || timer.state == .done {
                VStack(spacing: 10) {
                    HStack {
                        Text(TimerFormat.string(timer.remaining))
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if !timer.label.isEmpty {
                                Text(timer.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                            Text(timer.state == .done ? "Done" : (timer.state == .paused ? "Paused" : "Running"))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(IslandPalette.timer)
                        }
                    }
                    Meter(value: timer.progress, color: IslandPalette.timer, height: 5)
                    HStack(spacing: 8) {
                        if timer.state == .running {
                            TrayButton(title: "Pause", action: timer.pause)
                        } else if timer.state == .paused {
                            TrayButton(title: "Resume", action: timer.resume)
                        }
                        TrayButton(title: "Cancel", action: timer.cancel)
                    }
                }
            } else {
                QuickFocusRow(timer: timer)
            }
        }
    }
}

struct QuickFocusSection: View {
    @ObservedObject var timer: TimerEngine

    var body: some View {
        SectionCard(title: "Focus Timer", system: "timer") {
            QuickFocusRow(timer: timer)
        }
    }
}

struct QuickFocusRow: View {
    @ObservedObject var timer: TimerEngine

    var body: some View {
        HStack(spacing: 6) {
            ForEach([5, 15, 25, 45, 60], id: \.self) { m in
                Chip(title: "\(m)m") { timer.start(seconds: Double(m * 60), label: "Focus") }
            }
            TextField("min", text: Binding(
                get: { timer.draftMinutes },
                set: { timer.draftMinutes = $0 }
            ))
            .accessibilityLabel("Custom timer minutes")
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(width: 42)
            .padding(5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onSubmit { startCustom() }

            Chip(title: "Start", prominent: true, action: startCustom)
        }
    }

    private func startCustom() {
        let m = Double(timer.draftMinutes) ?? 0
        guard m > 0 else { return }
        timer.start(seconds: m * 60, label: "Focus")
    }
}

struct HarborSection: View {
    @ObservedObject var harbor: HarborStore

    var body: some View {
        SectionCard(title: "Harbor File Shelf · \(harbor.count)/\(HarborStore.maxItems)", system: "tray.full") {
            if harbor.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Drag files onto the notch to park them here.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                    Text("Pull them out when your destination is ready.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(harbor.items) { item in
                            HarborItemTile(item: item, harbor: harbor)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Toggle("Auto-park new screenshots", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: ShotWatch.watchShotsKey) as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: ShotWatch.watchShotsKey) }
            ))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.70))
            .toggleStyle(.switch)
            .tint(IslandPalette.transfer)
        }
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "video": return "film"
        case "audio": return "waveform"
        case "pdf": return "doc.richtext"
        case "folder": return "folder"
        default: return "doc"
        }
    }
}

struct HarborItemTile: View {
    var item: HarborStore.Item
    @ObservedObject var harbor: HarborStore
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tileColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tileColor.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: HarborSection.icon(for: item.kind))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tileColor)
                    )

                if isHovered {
                    Button(action: { harbor.remove(id: item.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85), Color.black.opacity(0.70))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }

            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 68)
        }
        .padding(6)
        .background(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture { harbor.reveal(id: item.id) }
        .onDrag {
            if let url = harbor.resolve(item) {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        }
        .help("Click to reveal in Finder · Drag to move anywhere")
    }

    private var tileColor: Color {
        switch item.kind {
        case "image": return Color(red: 0.25, green: 0.65, blue: 1.0)
        case "video": return Color(red: 0.70, green: 0.40, blue: 0.95)
        case "audio": return Color(red: 1.0, green: 0.35, blue: 0.55)
        case "pdf": return Color(red: 1.0, green: 0.35, blue: 0.30)
        case "folder": return Color(red: 1.0, green: 0.75, blue: 0.25)
        default: return Color(red: 0.55, green: 0.60, blue: 0.95)
        }
    }
}

struct QuickHubSection: View {
    @ObservedObject var clipboard: ClipboardEngine
    @ObservedObject var link: LinkHost

    var body: some View {
        VStack(spacing: 8) {
            if clipboard.enabled {
                ClipboardSection(clipboard: clipboard)
            }
            if link.enabled {
                LinkSection(link: link)
            }
        }
    }
}

struct ClipboardSection: View {
    @ObservedObject var clipboard: ClipboardEngine

    var body: some View {
        if clipboard.enabled {
            SectionCard(title: "Clipboard · \(clipboard.entries.count)/\(ClipboardEngine.maxEntries)", system: "doc.on.clipboard") {
                if clipboard.entries.isEmpty {
                    Text("Copied text gathers here (opt-in, local only).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    VStack(spacing: 4) {
                        ForEach(clipboard.entries.prefix(4)) { entry in
                            Button {
                                clipboard.copy(entry)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.on.doc.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(IslandPalette.clipboard)
                                        .frame(width: 16)
                                    Text(entry.preview)
                                        .font(.system(size: 11.5, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(relative(entry.addedAt))
                                        .font(.system(size: 9.5, design: .rounded).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.40))
                                    Image(systemName: "arrow.up.doc.on.clipboard")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.white.opacity(0.50))
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy \(entry.preview) to clipboard")
                        }
                    }
                }
                HStack {
                    Button("Clear history") { clipboard.clear() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .buttonStyle(.plain)
                    Spacer()
                    Text("opt-in · local only")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct LinkSection: View {
    @ObservedObject var link: LinkHost

    var body: some View {
        SectionCard(title: "iPhone Link", system: "iphone") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(link.peers.isEmpty ? Color.white.opacity(0.2) : Color.green)
                        .frame(width: 7, height: 7)
                    Text(link.peers.isEmpty ? "Waiting for iPhone…" : "\(link.peers.map(\.deviceName).joined(separator: ", ")) nearby")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }

                HStack {
                    Text("Code: \(link.code)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .tracking(2)
                    Spacer()
                    Button(action: {
                        if link.confirmRegen { link.regenerateCode() }
                        else { link.armRegenConfirm() }
                    }) {
                        Text(link.confirmRegen ? "Sure?" : "New")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(link.confirmRegen ? .red : .white.opacity(0.70))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Generate new pairing code")
                }

                if let r = link.remoteTimer {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.system(size: 11))
                            .foregroundStyle(IslandPalette.timer)
                            .accessibilityHidden(true)
                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            Text("\(r.peer): \(TimerFormat.string(liveRemaining(base: r.remaining, updatedAt: r.updatedAt, now: context.date)))")
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
    }
}

/// Waterline access: pending consent cards first, then the revocable grant list.
struct AccessSection: View {
    @ObservedObject var center: ExternalCenter

    var body: some View {
        if !center.pending.isEmpty || !center.grants.isEmpty {
            SectionCard(title: "Waterline access", system: "app.badge") {
                ForEach(center.pending) { req in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(req.source) wants the waterline")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(req.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Chip(title: "Allow") { center.approve(identityKey: req.identityKey) }
                            Chip(title: "Deny") { center.deny(identityKey: req.identityKey) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Allow \(req.source) on the waterline?")
                }
                ForEach(center.grants, id: \.key) { grant in
                    Toggle(grant.name, isOn: Binding(
                        get: { grant.allowed },
                        set: { center.setAllowed(identityKey: grant.key, allowed: $0) }
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .toggleStyle(.switch)
                    .tint(IslandPalette.external)
                    .accessibilityLabel("Waterline access for \(grant.name)")
                }
            }
        }
    }
}

/// Preferences & System Controls
struct SystemSection: View {
    @ObservedObject var island: IslandState
    @ObservedObject var hudEngine: HudEngine
    @ObservedObject var clipboard: ClipboardEngine
    @ObservedObject var link: LinkHost

    var body: some View {
        SectionCard(title: "Preferences & System", system: "slider.horizontal.3") {
            VStack(spacing: 6) {
                Toggle("Volume & brightness HUD at notch", isOn: Binding(
                    get: { hudEngine.enabled },
                    set: { hudEngine.setEnabled($0) }
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
                .toggleStyle(.switch)
                .tint(IslandPalette.timer)

                Toggle("Clipboard history shelf", isOn: Binding(
                    get: { clipboard.enabled },
                    set: { clipboard.setEnabled($0) }
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
                .toggleStyle(.switch)
                .tint(IslandPalette.clipboard)

                Toggle("iPhone link sync", isOn: Binding(
                    get: { link.enabled },
                    set: { link.setEnabled($0) }
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
                .toggleStyle(.switch)
                .tint(.green)

                Divider().background(.white.opacity(0.08))

                HStack {
                    Toggle("Open at Login", isOn: Binding(
                        get: { island.loginEnabled },
                        set: { island.commitLogin($0) }
                    ))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                    .toggleStyle(.switch)
                    .tint(.green)
                    .onAppear { island.refreshLogin() }

                    Spacer()

                    Button("Quit Notcher") { NSApp.terminate(nil) }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }
}

// MARK: - Bits

/// Hero card container: subtle lifted glass, hairline stroke, quiet label.
struct SectionCard<Content: View>: View {
    var title: String
    var system: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: system)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.5)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Deterministic progress meter (drawn, not ProgressView).
struct Meter: View {
    var value: Double
    var color: Color = .orange
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.16))
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * w)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: value)
        .accessibilityHidden(true)
    }
}

/// Album artwork: async URL fetch (Spotify) or inline data (Music), with a
/// graceful glyph fallback. Never blocks the UI thread; cached by URL/data.
struct ArtworkView: View {
    var url: URL?
    var data: Data?
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { artworkOverlay }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var artworkOverlay: some View {
        if let data, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else if let url {
            AsyncArtwork(url: url)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Minimal async fetch with a small in-memory cache (URL → NSImage).
struct AsyncArtwork: View {
    var url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }            .task(id: url) {
            if let cached = ArtworkCache.shared[url] {
                image = cached
                return
            }
            let u = url
            let img: NSImage? = await Task.detached(priority: .utility) {
                guard let (d, resp) = try? await URLSession.shared.data(from: u),
                      let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let decoded = NSImage(data: d) else { return nil }
                return decoded
            }.value
            if let img {
                ArtworkCache.shared[url] = img
                withAnimation(.easeOut(duration: 0.25)) { image = img }
            }
        }
    }
}

/// Image cache for album art (public for probe round-trip coverage).
public final class ArtworkCache: @unchecked Sendable {
    public static let shared = ArtworkCache()
    private var cache: [URL: NSImage] = [:]
    private let lock = NSLock()
    public subscript(url: URL) -> NSImage? {
        get { lock.withLock { cache[url] } }
        set { lock.withLock { cache[url] = newValue } }
    }
}

struct TrayButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .buttonStyle(PressableButtonStyle())
    }
}

struct TrayIconButton: View {
    var system: String
    var label: String
    var prominent = false
    var size: CGFloat = 30
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: prominent ? 13 : 11, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .accessibilityHidden(true)
                .frame(width: size, height: size)
                .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.10)),
                            in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

struct Chip: View {
    var title: String
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .buttonStyle(PressableButtonStyle())
    }
}

struct CompactMediaButton: View {
    var system: String
    var label: String
    var prominent: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: prominent ? 11 : 9.5, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .accessibilityHidden(true)
                .frame(width: prominent ? 28 : 24, height: prominent ? 28 : 24)
                .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.10)), in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

public enum TimerFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, r) }
        return String(format: "%02d:%02d", m, r)
    }
}

/// Live edge of a mirrored countdown: truth arrives every ~5 s, the clock
/// between updates is extrapolated locally (never below zero).
public func liveRemaining(base: Double, updatedAt: Date, now: Date) -> Double {
    max(0, base - now.timeIntervalSince(updatedAt))
}

// MARK: - Liquid Glass View Modifier

/// Metal / CoreAnimation-backed view modifier handling liquid glass material,
/// inner gradient border, drop shadows, and edge vignette blending.
public struct LiquidGlassModifier: ViewModifier {
    public let metrics: IslandMetrics
    public var dropTarget: Bool = false
    public var isCharging: Bool = false
    public var isLowBattery: Bool = false
    public var pointerInside: Bool = false

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
                    isLowBattery: isLowBattery
                )
            )
            .clipShape(MorphShape(m: metrics))
    }
}

public extension View {
    func liquidGlass(
        metrics: IslandMetrics,
        dropTarget: Bool = false,
        isCharging: Bool = false,
        isLowBattery: Bool = false,
        pointerInside: Bool = false
    ) -> some View {
        modifier(LiquidGlassModifier(
            metrics: metrics,
            dropTarget: dropTarget,
            isCharging: isCharging,
            isLowBattery: isLowBattery,
            pointerInside: pointerInside
        ))
    }
}
