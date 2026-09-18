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

    var body: some View {
        ZStack {
            // 1. Base Apple Vibrancy Glass
            VisualEffect(material: .popover)

            // 2. Luminous dark tonal gradient (Apple Liquid Glass depth)
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.70),
                    Color(red: 0.03, green: 0.03, blue: 0.04).opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 3. Drop target ambient illumination wash
            if dropTarget {
                LinearGradient(
                    colors: [Color.orange.opacity(0.24), Color.orange.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // 4. Subtle top crest reflection line
            LinearGradient(
                colors: [Color.white.opacity(0.35), Color.white.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 3)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .mask(MorphShape(m: metrics))
        .overlay(
            // 5. Specular rim light with directional gradient
            MorphShape(m: metrics)
                .stroke(
                    dropTarget
                        ? AnyShapeStyle(Color.orange.opacity(0.92))
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(pointerInside ? 0.38 : 0.26),
                                    Color.white.opacity(pointerInside ? 0.18 : 0.10),
                                    Color.white.opacity(0.04)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        ),
                    lineWidth: dropTarget ? 2 : 1
                )
                .allowsHitTesting(false)
        )
        // 6. Dual-stage depth shadows
        .shadow(color: .black.opacity(expanded ? 0.35 : 0.25),
                radius: expanded ? 8 : 5,
                y: expanded ? 4 : 2)
        .shadow(color: .black.opacity(expanded ? 0.45 : 0.32),
                radius: expanded ? 28 : 16,
                y: expanded ? 12 : 6)
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
    var onDropFiles: ([URL]) -> Void
    var onInteract: () -> Void

    public init(island: IslandState, timer: TimerEngine, media: MediaEngine,
                power: PowerEngine, harbor: HarborStore, link: LinkHost,
                center: ExternalCenter, clipboard: ClipboardEngine,
                hudEngine: HudEngine, privacy: PrivacyWatch,
                layout: NotchGeometry.Layout,
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
        self.onDropFiles = onDropFiles
        self.onInteract = onInteract
    }

    /// The island's single source of shape truth, recomputed on every state
    /// change; SwiftUI animates the MorphShape between them (one continuous
    /// spring interpolation — the whole transition).
    private var metrics: IslandMetrics {
        if island.mode == .compact, island.flash != nil {
            return IslandMetrics.compactSlim(layout)
        }
        return island.surfaceMetrics(layout: layout)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            surfaceLayer
            contentLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(island.contentAnimation, value: island.mode)
        .animation(island.contentAnimation, value: island.activity)
        .animation(island.contentAnimation, value: island.flash?.id)
        .animation(island.hudAnimation, value: island.hud)
        .environment(\.colorScheme, .dark)
        .background(DropCatcher(onDrop: onDropFiles, onHighlight: { island.setDropTarget($0) }))
        .onHover { hovering in
            island.pointerInside = hovering
            if hovering { island.hoverEntered() } else { island.hoverExited() }
        }
    }

    private var surfaceLayer: some View {
        SurfaceView(metrics: metrics,
                    strokeStyle: island.dropTarget
                        ? AnyShapeStyle(Color.orange.opacity(0.92))
                        : AnyShapeStyle(Color.white.opacity(island.pointerInside ? 0.22 : 0.14)),
                    strokeWidth: island.dropTarget ? 2 : 1,
                    expanded: island.mode == .expanded,
                    dropTarget: island.dropTarget,
                    pointerInside: island.pointerInside)
            .animation(island.motionAnimation, value: metrics)
    }

    private var contentLayer: some View {
        content
            .frame(width: metrics.width, height: metrics.height, alignment: .top)
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
                .frame(width: metrics.width, height: metrics.bodyH)
                .padding(.top, metrics.contentTop)
                .transition(.opacity)
        } else {
            compactContent
                .frame(width: metrics.width, height: metrics.bodyH)
                .padding(.top, metrics.contentTop)
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
        if let flash = island.flash {
            FlashContent(icon: flash.icon, text: flash.text)
        } else {
            switch island.activity {
            case .timer:
                TimerWingsContent(timer: timer)
            case .transfer:
                TransferWingsContent(link: link)
            case .remoteTimer:
                if let r = link.remoteTimer {
                    RemoteTimerPillContent(peer: r.peer, remaining: r.remaining,
                                           total: r.total, updatedAt: r.updatedAt)
                } else {
                    FlashContent(icon: "timer", text: "iPhone timer ended")
                }
            case .media:
                if media.appName != nil {
                    MediaSlabContent(media: media)
                } else {
                    FlashContent(icon: "music.note", text: "Nothing playing")
                }
            case .external:
                if let e = center.visible {
                    ExternalSlabContent(icon: e.icon, title: e.title, subtitle: e.subtitle,
                                        progress: e.progress, source: e.source)
                } else {
                    FlashContent(icon: "app.badge", text: "Waterline clear")
                }
            case .none:
                IdleHintContent()
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

/// The wings row: leading and trailing rails with flexible center separation.
/// Content renders BELOW the housing band with comfortable breathing room.
struct WingsRow<Leading: View, Trailing: View>: View {
    var chinW: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) { leading }
                .lineLimit(1)
            Spacer(minLength: max(16, chinW > 0 ? 24 : 16))
            HStack(spacing: 7) { trailing }
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}

struct FlashContent: View {
    var icon: String
    var text: String
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        } trailing: {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct TimerWingsContent: View {
    @ObservedObject var timer: TimerEngine
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.timer)
            Text(TimerFormat.string(timer.remaining))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        } trailing: {
            Text(timer.label.isEmpty ? "Focus" : timer.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct TransferWingsContent: View {
    @ObservedObject var link: LinkHost
    var chinW: CGFloat = 0
    var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.transfer)
        } trailing: {
            Text(link.receiving.map { "Receiving \($0.fileName)" } ?? "Incoming from iPhone")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
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

/// Media slab: artwork, title/artist with live waveform, scrubber, and tactile controls.
public struct MediaSlabContent: View {
    @ObservedObject var media: MediaEngine

    public init(media: MediaEngine) { self.media = media }

    public var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: media.artworkURL, data: media.artworkData)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(media.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .tracking(-0.25)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if media.playing {
                        WaveformIndicator(isPlaying: true, color: IslandPalette.media)
                    }
                }
                Text([media.artist, media.appName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let d = media.duration, d > 0 {
                    HStack(spacing: 5) {
                        Text(media.positionText)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.50))
                        Meter(value: media.progressFraction, color: IslandPalette.media, height: 3.5)
                            .frame(maxWidth: .infinity)
                        Text("-" + MediaEngine.mmss(max(0, d - media.livePosition)))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.50))
                    }
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                CompactMediaButton(system: "backward.fill", label: "Previous track") { media.previous() }
                CompactMediaButton(system: media.playing ? "pause.fill" : "play.fill",
                                   label: media.playing ? "Pause" : "Play",
                                   prominent: true) { media.playPause() }
                CompactMediaButton(system: "forward.fill", label: "Next track") { media.next() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }
}

/// External (waterline) slab: mirrors the media slab's language.
public struct ExternalSlabContent: View {
    public var icon: String
    public var title: String
    public var subtitle: String?
    public var progress: Double?
    public var source: String

    public init(icon: String, title: String, subtitle: String?, progress: Double?, source: String) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.source = source
    }

    public var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [IslandPalette.external.opacity(0.28), IslandPalette.external.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(IslandPalette.external.opacity(0.35), lineWidth: 1)
                )
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(IslandPalette.external)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle ?? source)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let p = progress {
                    Meter(value: p, color: IslandPalette.external, height: 3.5)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            Text(source)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(IslandPalette.external.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(IslandPalette.external.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.12), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    // 1. Hero contextual surface
                    if media.appName != nil {
                        NowPlayingSection(media: media)
                    }
                    if timer.isActive || timer.state == .done {
                        TimerSection(timer: timer)
                    } else if media.appName == nil {
                        QuickFocusSection(timer: timer)
                    }

                    // 2. Harbor File Shelf with direct drag-out
                    HarborSection(harbor: harbor)

                    // 3. Quick Hub (Clipboard & iPhone Link)
                    if clipboard.enabled || link.enabled {
                        QuickHubSection(clipboard: clipboard, link: link)
                    }

                    // 4. Waterline external access (if any)
                    AccessSection(center: center)

                    // 5. System, Preferences & Controls
                    SystemSection(island: island, hudEngine: hudEngine, clipboard: clipboard, link: link)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
        }
        .onTapGesture { onInteract() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "water.waves")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [IslandPalette.external, IslandPalette.timer],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Notcher")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            if privacy.privacyActive {
                HStack(spacing: 5) {
                    Circle()
                        .fill(privacy.cameraActive ? Color(red: 0.35, green: 0.82, blue: 1.0) : .orange)
                        .frame(width: 6, height: 6)
                    Text(privacy.cameraActive && privacy.micActive ? "cam · mic" : (privacy.cameraActive ? "camera" : "mic"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.08), in: Capsule())
            }

            if let p = power.percent {
                HStack(spacing: 4) {
                    Image(systemName: power.charging ? "bolt.fill" : "battery.75")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(power.charging ? .green : .white.opacity(0.85))
                    Text("\(Int(p))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.08), in: Capsule())
            }

            Button(action: { island.togglePin() }) {
                Image(systemName: island.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(island.pinned ? .orange : .white.opacity(0.70))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(island.pinned ? 0.16 : 0.06), in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(island.pinned ? "Unpin island" : "Pin island open")

            Button(action: { island.collapse() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Collapse island")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
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

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { artworkOverlay }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
