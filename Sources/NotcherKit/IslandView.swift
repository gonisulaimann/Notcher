import AppKit
import SwiftUI

// MARK: - AppKit bridges

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
            highlight?(true)
            return .copy
        }
        override func draggingExited(_: NSDraggingInfo?) {
            highlight?(false)
        }
        override func draggingEnded(_: NSDraggingInfo) {
            highlight?(false)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            highlight?(false)
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            handler?(urls)
            return true
        }
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
    var notchWidth: CGFloat
    var hasNotch: Bool
    var onDropFiles: ([URL]) -> Void
    /// Called on explicit clicks (never hover). The coordinator uses it to
    /// activate the app so keys/text fields work — without stealing focus
    /// on mere hover. Defaults to no-op for previews/snapshots.
    var onInteract: () -> Void = {}

    public init(island: IslandState, timer: TimerEngine, media: MediaEngine,
                power: PowerEngine, harbor: HarborStore, link: LinkHost,
                notchWidth: CGFloat, hasNotch: Bool,
                onDropFiles: @escaping ([URL]) -> Void,
                onInteract: @escaping () -> Void = {})
    {
        self.island = island
        self.timer = timer
        self.media = media
        self.power = power
        self.harbor = harbor
        self.link = link
        self.notchWidth = notchWidth
        self.hasNotch = hasNotch
        self.onDropFiles = onDropFiles
        self.onInteract = onInteract
    }

    public var body: some View {
        Group {
            switch island.mode {
            case .idle:
                IdleView(linked: !link.peers.isEmpty, notchWidth: notchWidth, hasNotch: hasNotch)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            case .compact:
                CompactView(island: island, timer: timer, media: media, link: link,
                            onInteract: onInteract)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            case .expanded:
                ExpandedView(island: island, timer: timer, media: media, power: power,
                             harbor: harbor, link: link, onInteract: onInteract)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .background(DropCatcher(onDrop: onDropFiles,
                                 onHighlight: { island.setDropTarget($0) }))
        .onHover { hovering in
            island.pointerInside = hovering
            if hovering { island.hoverEntered() } else { island.hoverExited() }
        }
        .animation(island.motionAnimation, value: island.mode)
        // The island is always dark glass (like the notch itself), no matter
        // the system appearance — this keeps white text legible in light mode.
        .environment(\.colorScheme, .dark)
    }
}

/// Smoked-glass background shared by the pill and the tray: a dark material
/// plus a translucent black lens so white content stays legible over both
/// light wallpapers and the light-mode menu bar. Layered: specular top edge,
/// lens, inner bottom shadow. `hovered` lifts the light without touching
/// layout (content redraw only — never a window op).
struct IslandGlass: View {
    var cornerRadius: CGFloat
    var hovered: Bool = false
    var body: some View {
        ZStack {
            VisualEffect()
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(hovered ? 0.27 : 0.32))
            VStack(spacing: 0) {
                // Specular top edge: catches light like real glass.
                LinearGradient(colors: [.white.opacity(hovered ? 0.30 : 0.20), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 2.5)
                Spacer()
                // Inner bottom shadow: gives the tray its depth.
                LinearGradient(colors: [.clear, .black.opacity(0.20)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// Pressed-state button style for the whole island: a tactile 4 % settle.
/// (`.plain` everywhere would leave buttons feeling dead.)
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Deterministic progress bar (ProgressView's linear tint renders
/// inconsistently across appearances, so the island draws its own meter).
struct Meter: View {
    var value: Double // 0...1
    var color: Color = .orange
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * w)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Idle: a seamless extension of the hardware notch

struct IdleView: View {
    var linked: Bool
    var notchWidth: CGFloat
    var hasNotch: Bool
    @ObservedObject private var breathe = Breathe()

    var body: some View {
        ZStack(alignment: .bottom) {
            CapsuleBlend(notchWidth: notchWidth, hasNotch: hasNotch)
            if linked {
                Circle()
                    .fill(Color.green.opacity(0.9))
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 3)
                    .opacity(breathe.on ? 0.45 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                            breathe.on = true
                        }
                    }
                    .accessibilityLabel("iPhone connected")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(linked ? "Notcher. iPhone connected." : "Notcher")
    }
}

final class Breathe: ObservableObject {
    @Published var on = false
}

/// Black capsule slightly wider than the housing so the physical notch melts
/// into the island; on notch-less displays a floating dark pill instead.
struct CapsuleBlend: View {
    var notchWidth: CGFloat
    var hasNotch: Bool

    var body: some View {
        GeometryReader { geo in
            let w = hasNotch ? max(geo.size.width, notchWidth + 72) : 210.0
            ZStack {
                Color.black
                // Faint bottom hairline: catches light like a glass edge.
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.white.opacity(0.14), .clear],
                        startPoint: .bottom, endPoint: .top
                    )
                    .frame(height: 1.5)
                }
            }
            .frame(width: w, height: geo.size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .clipShape(BlendShape(hasNotch: hasNotch))
        }
    }
}

/// Top edge square (merges with the bezel), bottom corners fully round.
/// On notch-less displays a plain continuous rounded rect instead.
struct BlendShape: Shape {
    var hasNotch: Bool
    func path(in rect: CGRect) -> Path {
        if !hasNotch {
            return RoundedRectangle(cornerRadius: 15, style: .continuous).path(in: rect)
        }
        let r: CGFloat = min(12, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Compact: exactly one live activity

struct CompactView: View {
    @ObservedObject var island: IslandState
    @ObservedObject var timer: TimerEngine
    @ObservedObject var media: MediaEngine
    @ObservedObject var link: LinkHost
    var onInteract: () -> Void = {}

    var body: some View {
        Button(action: { onInteract(); island.togglePin() }) {
            HStack(spacing: 8) {
                content
                    // Identity follows the live-activity/flash: every handoff
                    // replaces (morphs) the content instead of snapping it.
                    .id("compact-\(island.activity)-\(island.flash?.id.uuidString ?? "-")")
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(island.contentAnimation,
                       value: "compact-\(island.activity)-\(island.flash?.id.uuidString ?? "-")")
        }
        .buttonStyle(PressableButtonStyle())
        .background(IslandGlass(cornerRadius: 20, hovered: island.pointerInside))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(island.dropTarget ? .orange.opacity(0.9)
                          : .white.opacity(island.pointerInside ? 0.22 : 0.14),
                          lineWidth: island.dropTarget ? 2.5 : 1))
        // Drop bloom: a translucent orange wash over the pill. Overlay, not
        // scale — scaling would clip against the tight window frame.
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.orange.opacity(island.dropTarget ? 0.12 : 0)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .animation(island.motionAnimation, value: island.dropTarget)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        if let flash = island.flash {
            Image(systemName: flash.icon)
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .semibold))
            Text(flash.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            switch island.activity {
            case .timer:
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13, weight: .semibold))
                Text(TimerFormat.string(timer.remaining))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Meter(value: timer.progress, color: .orange)
                    .frame(width: 64)
                if !timer.label.isEmpty {
                    Text(timer.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            case .transfer:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .semibold))
                if let r = link.receiving {
                    Text("Receiving \(r.fileName)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(r.got)/\(r.total)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("Incoming from iPhone")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                }
            case .remoteTimer:
                if let r = link.remoteTimer {
                    RemoteTimerPillContent(peer: r.peer, remaining: r.remaining,
                                           total: r.total, updatedAt: r.updatedAt)
                } else {
                    // Mirror expired between resolve and render; recede text.
                    Text("iPhone timer ended")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .media:
                Image(systemName: media.playing ? "waveform" : "music.note")
                    .foregroundStyle(.pink)
                    .font(.system(size: 13, weight: .semibold))
                Text(mediaTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                CompactMediaButton(system: media.playing ? "pause.fill" : "play.fill",
                                   label: media.playing ? "Pause" : "Play")
                {
                    media.playPause()
                }
                CompactMediaButton(system: "forward.fill", label: "Next track") { media.next() }
            case .none:
                Image(systemName: "water.waves")
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text("Notcher")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var mediaTitle: String {
        let t = media.title ?? "Nothing playing"
        if let a = media.artist, !a.isEmpty { return "\(t) — \(a)" }
        return t
    }

    private var accessibilityText: String {
        if let flash = island.flash { return flash.text }
        switch island.activity {
        case .timer: return "Timer, \(TimerFormat.string(timer.remaining)) remaining"
        case .transfer: return "Receiving file from iPhone"
        case .remoteTimer:
            if let r = link.remoteTimer {
                return "iPhone timer from \(r.peer), \(TimerFormat.string(r.remaining)) remaining"
            }
            return "iPhone timer"
        case .media: return "Now playing, \(mediaTitle)"
        case .none: return "Notcher"
        }
    }
}

/// Pure pill content for a mirrored iPhone timer: peer name plus a locally
/// extrapolated live countdown (truth arrives ~every 5 s). Value types only,
/// so the snapshot harness can render it without a live session.
public struct RemoteTimerPillContent: View {
    public var peer: String
    public var remaining: Double
    public var total: Double
    public var updatedAt: Date

    public init(peer: String, remaining: Double, total: Double, updatedAt: Date) {
        self.peer = peer
        self.remaining = remaining
        self.total = total
        self.updatedAt = updatedAt
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .foregroundStyle(.orange)
                .font(.system(size: 13, weight: .semibold))
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(TimerFormat.string(liveRemaining(base: remaining,
                                                      updatedAt: updatedAt,
                                                      now: context.date)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Text(peer)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        // Accessibility: the containing pill button carries the label.
        .accessibilityHidden(true)
    }
}

struct CompactMediaButton: View {    var system: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
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
    var onInteract: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(.white.opacity(0.08))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    TimerSection(timer: timer)
                    NowPlayingSection(media: media)
                    HarborSection(harbor: harbor)
                    LinkSection(link: link)
                    FooterRow(island: island)
                }
                .padding(14)
            }
        }
        .onTapGesture { onInteract() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IslandGlass(cornerRadius: 24, hovered: island.pointerInside))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(island.dropTarget ? .orange.opacity(0.9)
                          : .white.opacity(island.pointerInside ? 0.22 : 0.14),
                          lineWidth: island.dropTarget ? 2.5 : 1))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.orange.opacity(island.dropTarget ? 0.10 : 0)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .animation(island.motionAnimation, value: island.dropTarget)
    }

    private var header: some View {
        HStack {
            Image(systemName: "water.waves")
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            Text("Notcher")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
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

// MARK: Sections

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
    }
}

struct TimerSection: View {
    @ObservedObject var timer: TimerEngine

    var body: some View {
        SectionCard(title: "Timer", system: "timer") {
            if timer.isActive || timer.state == .done {
                HStack {
                    Text(TimerFormat.string(timer.remaining))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if !timer.label.isEmpty {
                            Text(timer.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Text(timer.state == .done ? "Done" : (timer.state == .paused ? "Paused" : "Running"))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                Meter(value: timer.progress, color: .orange)
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

struct NowPlayingSection: View {
    @ObservedObject var media: MediaEngine
    var body: some View {
        SectionCard(title: "Now Playing", system: "music.note") {
            if media.appName != nil {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title ?? "Unknown track")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .tracking(-0.2)
                            .lineLimit(1)
                        Text(((media.artist ?? "") + (media.appName.map { " · \($0)" } ?? "")))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                    TrayIconButton(system: "backward.fill", label: "Previous track", action: media.previous)
                    TrayIconButton(system: media.playing ? "pause.fill" : "play.fill",
                                   label: media.playing ? "Pause" : "Play", action: media.playPause)
                    TrayIconButton(system: "forward.fill", label: "Next track", action: media.next)
                }
            } else {
                Text("Nothing playing in Music or Spotify.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
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
                        Image(systemName: "timer").font(.system(size: 11)).foregroundStyle(.orange).accessibilityHidden(true)
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
                    HStack(spacing: 6) {
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
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.1), in: Circle())
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
            .background(prominent ? .white : .white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .buttonStyle(PressableButtonStyle())
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
