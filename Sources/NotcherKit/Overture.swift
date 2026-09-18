import Foundation
import SwiftUI

/// Godmode overture: the one-time first-launch moment (~4.5 s, never loops).
///
/// v2 design: the island surface itself tells the story, in ONE continuous
/// spring morph inside the fixed canvas window —
///   melt-in from nothing → greet in 8 languages → teach the three
///   surfaces (timer wings / file slab / media slab) → recede to idle.
/// No second window, no cross-screen arc, no window resizing — the same
/// morph language the user is about to learn is the one that teaches it.
/// Skippable on any click/Escape; Reduce Motion collapses to a short fade.
///
/// The beat machine is pure and deterministic (probed without timers);
/// content beats map to real IslandState surfaces rendered by OvertureView.
@MainActor
public final class Overture: ObservableObject {
    public static let greetings = ["hello", "hola", "bonjour", "こんにちは", "ciao", "olá", "hej", "salut"]

    public enum Beat: Equatable, Sendable {
        case melt          // surface grows out of the housing
        case greetings     // multilingual hello montage
        case vocabTimer    // timer wings
        case vocabFile     // harbor slab
        case vocabMedia    // media slab
        case recede        // melt back to idle
    }

    @Published public private(set) var beatIndex = 0
    @Published public private(set) var greetingIndex = 0

    public let reduceMotion: Bool
    public private(set) var beats: [Beat] = []
    /// Seconds per beat (content switches when the morph has settled).
    public private(set) var durations: [TimeInterval] = []
    public private(set) var finished = false

    public var onDone: (() -> Void)?

    private var ticker: Timer?
    private var greetTicker: Timer?
    private var startDate = Date()
    private var schedule: [TimeInterval] = []

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        if reduceMotion {
            beats = [.melt, .greetings, .recede]
            durations = [0.2, 0.9, 0.3]
        } else {
            beats = [.melt, .greetings, .vocabTimer, .vocabFile, .vocabMedia, .recede]
            durations = [0.7, 1.1, 0.9, 0.9, 0.9, 0.6]
        }
        var acc: TimeInterval = 0
        for d in durations {
            acc += d
            schedule.append(acc)
        }
    }

    public var count: Int { beats.count }

    public func start() {
        guard !finished else { return }
        startDate = Date()
        beatIndex = 0
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        let g = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceGreeting() }
        }
        RunLoop.main.add(g, forMode: .common)
        greetTicker = g
    }

    /// Advance exactly one beat. Returns false when the sequence is done.
    @discardableResult
    public func advance() -> Bool {
        guard !finished else { return false }
        if beatIndex + 1 >= beats.count {
            finish()
            return false
        }
        beatIndex += 1
        return true
    }

    public func advanceGreeting() {
        guard !finished, !reduceMotion, beats[beatIndex] == .greetings else { return }
        greetingIndex = (greetingIndex + 1) % Self.greetings.count
    }

    public func cancel() {
        finish()
    }

    private func pump() {
        guard !finished else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        while beatIndex + 1 < beats.count, elapsed >= schedule[beatIndex] {
            beatIndex += 1
        }
        if elapsed >= schedule[beats.count - 1] {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        ticker?.invalidate()
        ticker = nil
        greetTicker?.invalidate()
        greetTicker = nil
        onDone?()
    }
}

/// The overture surface: the island shape mid-morph with beat content.
/// Rendered inside the island's own canvas window — same MorphShape, same
/// springs, so the user's first frame IS the product's design language.
public struct OvertureView: View {
    @ObservedObject var overture: Overture
    var onTap: () -> Void

    public init(overture: Overture, onTap: @escaping () -> Void = {}) {
        self.overture = overture
        self.onTap = onTap
    }

    public var body: some View {
        OvertureBeatContent(beat: overture.beats[overture.beatIndex],
                            greetingIndex: overture.greetingIndex)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .accessibilityLabel("Welcome to Notcher. Click to skip the introduction.")
    }
}

/// Beat content driven by plain values — the live app renders this from
/// `IslandState.overtureBeat` without holding the Overture object; the
/// greeting montage ticks itself via TimelineView while that beat shows.
public struct OvertureBeatContent: View {
    public var beat: Overture.Beat
    public var greetingIndex: Int

    public init(beat: Overture.Beat, greetingIndex: Int = 0) {
        self.beat = beat
        self.greetingIndex = greetingIndex
    }

    public var body: some View {
        Group {
            switch beat {
            case .melt, .recede:
                Color.clear.frame(height: 10)
            case .greetings:
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let idx = Int(context.date.timeIntervalSinceReferenceDate * 5)
                        % Overture.greetings.count
                    Text(Overture.greetings[idx])
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(-0.3)
                        .id("greet-\(idx)")
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            case .vocabTimer:
                vocabRow(icon: "timer", tint: IslandPalette.timer,
                         title: "25:00", subtitle: "your countdown lives here")
            case .vocabFile:
                vocabRow(icon: "tray.and.arrow.down.fill", tint: IslandPalette.transfer,
                         title: "drag anything in", subtitle: "it parks until you flick it out")
            case .vocabMedia:
                vocabRow(icon: "waveform", tint: IslandPalette.media,
                         title: "what's playing", subtitle: "with the art, right at the notch")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: beat)
    }

    private func vocabRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .id("vocab-\(title)")
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }
}
