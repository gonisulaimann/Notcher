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

    var body: some View {
        ZStack {
            VisualEffect()
            MorphShape(m: metrics)
                .fill(Color.black.opacity(0.5))
            LinearGradient(colors: [.white.opacity(0.16), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .mask(MorphShape(m: metrics))
        .overlay(
            MorphShape(m: metrics)
                .stroke(strokeStyle, lineWidth: strokeWidth)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(expanded ? 0.42 : 0.30),
                radius: expanded ? 22 : 14,
                y: expanded ? 9 : 5)
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
        var m = island.surfaceMetrics(layout: layout)
        if island.mode == .compact, island.flash != nil {
            // Flashes announce in the wings form so text flanks the housing.
            let slim = IslandMetrics.compactSlim(layout)
            m.width = slim.width
            m.chinW = slim.chinW
        }
        return m
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
                        ? AnyShapeStyle(.orange.opacity(0.9))
                        : AnyShapeStyle(.white.opacity(island.pointerInside ? 0.20 : 0.12)),
                    strokeWidth: island.dropTarget ? 2 : 1,
                    expanded: island.mode == .expanded)
            .animation(island.motionAnimation, value: metrics)
    }

    private var contentLayer: some View {
        content
            .frame(width: metrics.width, alignment: .top)
            .animation(island.motionAnimation, value: metrics)
    }

    @ViewBuilder
    private var content: some View {
        if let beat = island.overtureBeat {
            OvertureBeatContent(beat: beat)
                .padding(.top, metrics.contentTop)
        } else if island.mode == .hud, let hud = island.hud {
            HudView(content: hud)
                .padding(.top, metrics.contentTop + 6)
        } else if island.mode == .expanded {
            ExpandedView(island: island, timer: timer, media: media, power: power,
                         harbor: harbor, link: link, center: center,
                         clipboard: clipboard, hudEngine: hudEngine,
                         privacy: privacy, onInteract: onInteract)
                .padding(.top, metrics.contentTop)
                .transition(.opacity)
        } else {
            compactContent
                .padding(.top, metrics.contentTop + (metrics.shoulder == 0 ? 0 : 2))
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

/// The wings row: leading and trailing rails with an optional center gap.
/// All compact content renders BELOW the housing band (contentTop), so the
/// rails are a layout language, not a collision workaround; the gap only
/// appears where a row intentionally straddles housing-height (none today).
struct WingsRow<Leading: View, Trailing: View>: View {
    var chinW: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GeometryReader { geo in
            let pad: CGFloat = 13
            let railW = max(10, (geo.size.width - pad * 2 - chinW) / 2)
            HStack(spacing: 0) {
                HStack(spacing: 7) { leading }
                    .frame(width: railW, alignment: .leading)
                Spacer(minLength: chinW)
                HStack(spacing: 7) { trailing }
                    .frame(width: railW, alignment: .trailing)
            }
            .padding(.horizontal, pad)
        }
        .frame(maxHeight: .infinity)
    }
}

struct FlashContent: View {
    var icon: String
    var text: String
    var chinW: CGFloat = 120
    var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        } trailing: {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.7)
        }
    }
}

struct TimerWingsContent: View {
    @ObservedObject var timer: TimerEngine
    var chinW: CGFloat = 120
    var body: some View {
        WingsRow(chinW: chinW) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandPalette.timer)
            Text(TimerFormat.string(timer.remaining))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        } trailing: {
            Text(timer.label.isEmpty ? "Focus" : timer.label)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct TransferWingsContent: View {
    @ObservedObject var link: LinkHost
    var chinW: CGFloat = 120
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
                .minimumScaleFactor(0.7)
        }
    }
}

struct IdleHintContent: View {
    var chinW: CGFloat = 120
    var body: some View {
        WingsRow(chinW: chinW) {
            Spacer(minLength: 0)
        } trailing: {
            Spacer(minLength: 0)
        }
    }
}

/// Media slab: artwork, title/artist, and controls in the body band below
/// the housing. The morph that swaps media in/out is the pill itself growing
/// a body — never a content crossfade inside a fixed pill.
public struct MediaSlabContent: View {
    @ObservedObject var media: MediaEngine

    public init(media: MediaEngine) { self.media = media }

    public var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: media.artworkURL, data: media.artworkData)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title ?? "Nothing playing")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([media.artist, media.appName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            CompactMediaButton(system: "backward.fill", label: "Previous track") { media.previous() }
            CompactMediaButton(system: media.playing ? "pause.fill" : "play.fill",
                               label: media.playing ? "Pause" : "Play") { media.playPause() }
            CompactMediaButton(system: "forward.fill", label: "Next track") { media.next() }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
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
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(IslandPalette.external.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(IslandPalette.external)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle ?? source)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let p = progress {
                    Meter(value: p, color: IslandPalette.external)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

/// Remote timer keeps the wings form (data pill).
public struct RemoteTimerPillContent: View {
    public var peer: String
    public var remaining: Double
    public var total: Double
    public var updatedAt: Date
    public var chinW: CGFloat = 120

    public init(peer: String, remaining: Double, total: Double, updatedAt: Date,
                chinW: CGFloat = 120) {
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
            }
        } trailing: {
            Text(peer)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 22)
            Meter(value: content.value,
                  color: isMuted ? .white.opacity(0.4) : .white.opacity(0.92),
                  height: 6)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
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
            Divider().background(.white.opacity(0.08))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    NowPlayingSection(media: media)
                    TimerSection(timer: timer)
                    HarborSection(harbor: harbor)
                    ClipboardSection(clipboard: clipboard)
                    LinkSection(link: link)
                    AccessSection(center: center)
                    PrivacySection(privacy: privacy)
                    TogglesSection(island: island, hudEngine: hudEngine)
                    FooterRow(island: island)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .onTapGesture { onInteract() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "water.waves")
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            Text("Notcher")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if privacy.privacyActive {
                HStack(spacing: 4) {
                    Image(systemName: privacy.cameraActive ? "video.fill" : "mic.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(privacy.cameraActive ? Color(red: 0.35, green: 0.82, blue: 1.0) : .orange)
                    Text(privacy.cameraActive && privacy.micActive ? "cam · mic" : (privacy.cameraActive ? "camera" : "mic"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if let p = power.percent {
                HStack(spacing: 4) {
                    Image(systemName: power.charging ? "bolt.fill" : "battery.50")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("\(Int(p))%")
                        .font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            Button(action: { island.togglePin() }) {
                Image(systemName: island.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(island.pinned ? .orange : .white.opacity(0.7))
                    .accessibilityHidden(true)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(island.pinned ? "Unpin island" : "Pin island open")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

// MARK: - Tray sections

/// Hero media card: artwork, title/artist, transport, progress scrubber.
struct NowPlayingSection: View {
    @ObservedObject var media: MediaEngine

    var body: some View {
        SectionCard(title: "Now Playing", system: "music.note") {
            if media.appName != nil {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        ArtworkView(url: media.artworkURL, data: media.artworkData)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(media.title ?? "Unknown track")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .tracking(-0.3)
                                .lineLimit(1)
                            Text([media.artist, media.appName].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Text(media.positionText)
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34, alignment: .leading)
                        Meter(value: media.progressFraction, color: IslandPalette.media, height: 4)
                        Text(media.durationText)
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34, alignment: .trailing)
                    }
                    HStack(spacing: 18) {
                        Spacer()
                        TrayIconButton(system: "backward.fill", label: "Previous track", action: media.previous)
                        TrayIconButton(system: media.playing ? "pause.fill" : "play.fill",
                                       label: media.playing ? "Pause" : "Play",
                                       prominent: true, action: media.playPause)
                        TrayIconButton(system: "forward.fill", label: "Next track", action: media.next)
                        Spacer()
                    }
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
                HStack {
                    Text(TimerFormat.string(timer.remaining))
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if !timer.label.isEmpty {
                            Text(timer.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Text(timer.state == .done ? "Done" : (timer.state == .paused ? "Paused" : "Running"))
                            .font(.system(size: 11)).foregroundStyle(IslandPalette.timer)
                    }
                }
                Meter(value: timer.progress, color: IslandPalette.timer)
                HStack(spacing: 8) {
                    if timer.state == .running {
                        TrayButton(title: "Pause", action: timer.pause)
                    } else if timer.state == .paused {
                        TrayButton(title: "Resume", action: timer.resume)
                    }
                    TrayButton(title: "Cancel", action: timer.cancel)
                }
            } else {
                HStack(spacing: 6) {
                    ForEach([5, 15, 25, 60], id: \.self) { m in
                        Chip(title: "\(m)m") { timer.start(seconds: Double(m * 60), label: "Focus") }
                    }
                    TextField("min", text: Binding(
                        get: { timer.draftMinutes },
                        set: { timer.draftMinutes = $0 }
                    ))
                        .accessibilityLabel("Custom timer minutes")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                        .padding(5)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { startCustom() }
                    Chip(title: "Start", prominent: true, action: startCustom)
                }
            }
        }
    }

    private func startCustom() {
        let m = Double(timer.draftMinutes) ?? 0
        guard m > 0 else { return }
        timer.start(seconds: m * 60, label: "Timer")
    }
}

struct HarborSection: View {
    @ObservedObject var harbor: HarborStore
    var body: some View {
        SectionCard(title: "Harbor · \(harbor.count)/\(HarborStore.maxItems)", system: "tray.full") {
            if harbor.items.isEmpty {
                Text("Drag files onto the notch to park them here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(spacing: 4) {
                    ForEach(harbor.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: HarborSection.icon(for: item.kind))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                                .accessibilityHidden(true)
                                .frame(width: 18)
                            Text(item.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(action: { harbor.remove(id: item.id) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .accessibilityHidden(true)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("Remove \(item.name)")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { harbor.reveal(id: item.id) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Reveal \(item.name) in Finder")
                    }
                }
            }
            Toggle("Park new screenshots", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: ShotWatch.watchShotsKey) as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: ShotWatch.watchShotsKey) }
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.7))
            .toggleStyle(.switch)
            .tint(.orange)
            .accessibilityLabel("Automatically park new screenshots from the Desktop")
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

struct ClipboardSection: View {
    @ObservedObject var clipboard: ClipboardEngine
    var body: some View {
        if clipboard.enabled {
            SectionCard(title: "Clipboard · \(clipboard.entries.count)/\(ClipboardEngine.maxEntries)", system: "doc.on.clipboard") {
                if clipboard.entries.isEmpty {
                    Text("Copied text gathers here (opt-in, local only).")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    VStack(spacing: 4) {
                        ForEach(clipboard.entries) { entry in
                            Button {
                                clipboard.copy(entry)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.on.doc.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(IslandPalette.clipboard)
                                        .frame(width: 16)
                                    Text(entry.preview)
                                        .font(.system(size: 12, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(relative(entry.addedAt))
                                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.4))
                                    Image(systemName: "arrow.up.doc.on.clipboard")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .background(.white.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy \(entry.preview) to clipboard")
                        }
                    }
                }
                HStack {
                    Button("Clear history") { clipboard.clear() }
                        .font(.system(size: 11))
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
            Toggle(isOn: Binding(get: { link.enabled }, set: { link.setEnabled($0) })) {
                Text(link.peers.isEmpty ? "Waiting for iPhone…" : "\(link.peers.map(\.deviceName).joined(separator: ", ")) nearby")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(.green)

            if link.enabled {
                HStack {
                    Text("Pairing code")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(link.code)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .tracking(3)
                    Button(action: {
                        if link.confirmRegen { link.regenerateCode() }
                        else { link.armRegenConfirm() }
                    }) {
                        Text(link.confirmRegen ? "Sure?" : "New")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(link.confirmRegen ? .red : .white.opacity(0.7))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Generate new pairing code")
                }
                if let r = link.remoteTimer {
                    HStack(spacing: 6) {
                        Image(systemName: "timer").font(.system(size: 11)).foregroundStyle(IslandPalette.timer).accessibilityHidden(true)
                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            Text("\(r.peer): \(TimerFormat.string(liveRemaining(base: r.remaining, updatedAt: r.updatedAt, now: context.date)))")
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    }
                }
                if link.peers.isEmpty {
                    Text("Open the Notcher companion on your iPhone (same Wi-Fi) and enter this code.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    HStack {
                        TextField("Send text to iPhone…", text: Binding(
                            get: { link.draftMessage },
                            set: { link.draftMessage = $0 }
                        ))
                            .accessibilityLabel("Message to send to iPhone")
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .onSubmit(sendMessage)
                        Chip(title: "Send", prominent: true, action: sendMessage)
                        Chip(title: "File…") { sendFile() }
                    }
                }
            } else {
                Text("Link is off. Nothing leaves this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func sendMessage() {
        let t = link.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        link.sendText(t)
        link.draftMessage = ""
    }

    private func sendFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            link.sendFile(url)
        }
    }
}

/// Waterline access: pending consent cards first, then the revocable grant
/// list. This is the permission surface for IslandKit.
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

struct PrivacySection: View {
    @ObservedObject var privacy: PrivacyWatch
    var body: some View {
        SectionCard(title: "Privacy sensors", system: "eye.slash") {
            HStack(spacing: 12) {
                sensor("Camera", icon: "video.fill", active: privacy.cameraActive,
                       color: Color(red: 0.35, green: 0.82, blue: 1.0))
                sensor("Microphone", icon: "mic.fill", active: privacy.micActive, color: .orange)
                Spacer()
                Text("live, public APIs")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func sensor(_ name: String, icon: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? color : Color.white.opacity(0.15))
                .frame(width: 7, height: 7)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(active ? 0.9 : 0.35))
            Text(active ? "\(name) in use" : name)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(active ? 0.9 : 0.5))
        }
    }
}

/// Toggle center for the new surfaces (replaces scattered options).
struct TogglesSection: View {
    @ObservedObject var island: IslandState
    @ObservedObject var hudEngine: HudEngine

    var body: some View {
        SectionCard(title: "Surfaces", system: "switch.2") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Volume & brightness HUD at the notch", isOn: Binding(
                    get: { hudEngine.enabled },
                    set: { hudEngine.setEnabled($0) }
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .toggleStyle(.switch)
                .tint(IslandPalette.timer)
                Toggle("Remember clipboard history", isOn: Binding(
                    get: { clipboardBinding },
                    set: { ClipboardEngine.setEnabled($0) }
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .toggleStyle(.switch)
                .tint(IslandPalette.clipboard)
            }
        }
    }

    private var clipboardBinding: Bool {
        UserDefaults.standard.object(forKey: ClipboardEngine.enabledKey) as? Bool ?? false
    }
}

struct FooterRow: View {
    @ObservedObject var island: IslandState
    var body: some View {
        HStack {
            Toggle("Open at Login", isOn: Binding(
                get: { island.loginEnabled },
                set: { island.commitLogin($0) }
            ))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .toggleStyle(.switch)
                .tint(.green)
                .onAppear { island.refreshLogin() }
            Spacer()
            Button("Quit Notcher") { NSApp.terminate(nil) }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .buttonStyle(PressableButtonStyle())
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.4)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
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

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private var cache: [URL: NSImage] = [:]
    private let lock = NSLock()
    subscript(url: URL) -> NSImage? {
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
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .accessibilityHidden(true)
                .frame(width: 28, height: 28)
                .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)),
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
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.10), in: Circle())
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
