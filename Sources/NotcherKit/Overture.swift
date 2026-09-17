import Foundation

/// Godmode overture: the one-time first-launch moment (~3.5 s, never loops).
///
/// A glowing pill arcs from the screen corner to the notch, locks in with a
/// multilingual greeting montage, teaches the 3-beat vocabulary (timer →
/// file swallow → waveform), then recedes into the idle melt. Skippable on
/// any click/Escape; Reduce Motion collapses it to a short fade.
///
/// Design constraints honored:
/// - No separate window layer: the existing island panel is driven frame by
///   frame through IslandController.showCustom (argued here, not assumed:
///   a second window would double every ordering/z/archive edge the product
///   spent two sessions eliminating).
/// - Deterministic: beats advance through an explicit schedule; `advance()`
///   steps one beat synchronously so probes assert exact frames/content
///   without timers.
@MainActor
public final class Overture: ObservableObject {
    public static let greetings = ["hello", "hola", "bonjour", "こんにちは", "ciao", "olá", "hej", "salut"]

    /// Beat kinds in order. Full sequence; reduced motion uses a subset.
    public enum Beat: Equatable, Sendable {
        case corner
        case arc(Int)          // 0..<arcSteps
        case greetings
        case vocabTimer
        case vocabFile
        case vocabWave
        case recede
    }

    public static let arcSteps = 3

    @Published public private(set) var beatIndex = 0
    @Published public private(set) var greetingIndex = 0

    public let reduceMotion: Bool
    public private(set) var beats: [Beat] = []
    public private(set) var frames: [CGRect] = []
    public private(set) var finished = false

    public var onDone: (() -> Void)?

    private var ticker: Timer?
    private var greetTicker: Timer?
    private var startDate = Date()

    /// Schedule: beat index -> seconds after start.
    private var schedule: [TimeInterval] = []

    public init(corner: CGRect, notchFrame: CGRect, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        if reduceMotion {
            beats = [.corner, .greetings, .recede]
            frames = [corner, notchFrame, notchFrame]
            schedule = [0, 0.2, 1.2, 1.5]
        } else {
            var b: [Beat] = [.corner]
            var f: [CGRect] = [corner]
            for i in 0 ..< Self.arcSteps {
                b.append(.arc(i))
                f.append(Self.lerp(corner, notchFrame, t: Self.easeOutCubic(Double(i + 1) / Double(Self.arcSteps + 1))))
            }
            b += [.greetings, .vocabTimer, .vocabFile, .vocabWave, .recede]
            f += [notchFrame, notchFrame, notchFrame, notchFrame, notchFrame]
            beats = b
            frames = f
            // Start times per beat + end time: arc 1.1 s, greetings 1.0 s,
            // vocab 3 x 0.4 s, recede. Total ~3.65 s.
            schedule = [0, 0.35, 0.6, 0.85, 1.1, 2.1, 2.5, 2.9, 3.3, 3.65]
        }
        assert(schedule.count == beats.count + 1)
    }

    public var count: Int { beats.count }

    public func frame(at index: Int) -> CGRect {
        frames[min(max(index, 0), frames.count - 1)]
    }

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
        while beatIndex + 1 < beats.count, elapsed >= schedule[beatIndex + 1] {
            beatIndex += 1
        }
        if elapsed >= schedule[beats.count] {
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

    public static func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    public static func lerp(_ a: CGRect, _ b: CGRect, t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }
}
