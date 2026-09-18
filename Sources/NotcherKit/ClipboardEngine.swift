import AppKit
import Combine

/// Clipboard history: opt-in, local-only, text-only ring buffer.
///
/// Constitution honored: OFF by default (reading the clipboard is a privacy
/// event, so the user must ask for it), nothing ever leaves the machine, and
/// only text is captured (images/files stay out of scope on purpose).
/// Capture is poll-based on the general pasteboard changeCount — no private
/// hooks, no launch agents. Sensitive-content hygiene: entries are never
/// persisted to disk; history dies with the process by design.
@MainActor
public final class ClipboardEngine: ObservableObject {
    public struct Entry: Identifiable, Equatable {
        public var id = UUID()
        public var text: String
        public var addedAt: Date

        /// Single-line preview, whitespace-collapsed, capped for UI.
        public var preview: String {
            let oneLine = text
                .replacingOccurrences(of: "\n", with: " ⏎ ")
                .replacingOccurrences(of: "\t", with: " ")
            let collapsed = oneLine.replacingOccurrences(
                of: #"\s+"#, with: " ", options: .regularExpression)
            return String(collapsed.prefix(120))
        }
    }

    public static let maxEntries = 10
    public static let enabledKey = "clipboard.enabled"
    /// Skip rapid machine-generated duplicates (some tools copy twice).
    static let dedupeWindow: TimeInterval = 0.4

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var enabled: Bool

    private var poll: Timer?
    private var lastCount: Int
    private var lastText = ""
    private var lastTime: TimeInterval = 0

    public init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        lastCount = NSPasteboard.general.changeCount
        if enabled { start() }
    }

    public static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    /// Pure acceptance rule (unit-probed): text-bearing, non-duplicate,
    /// respects the dedupe window for machine double-copies.
    public static func shouldCapture(text: String?, lastText: String,
                                     secondsSinceLast: TimeInterval) -> Bool {
        guard let text, !text.isEmpty, !text.allSatisfy({ $0.isWhitespace }) else { return false }
        if text == lastText, secondsSinceLast < dedupeWindow { return false }
        return true
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        Self.setEnabled(on)
        if on { start() } else { stop(); entries.removeAll() }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Re-copy an entry to the pasteboard (history does not reorder —
    /// predictable and simple).
    public func copy(_ entry: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
    }

    private func start() {
        guard poll == nil else { return }
        lastCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func stop() {
        poll?.invalidate()
        poll = nil
    }

    private func scan() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard let text = pb.string(forType: .string) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.shouldCapture(text: text, lastText: lastText,
                                 secondsSinceLast: now - lastTime) else { return }
        lastText = text
        lastTime = now
        entries.insert(Entry(text: text, addedAt: Date()), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }
}
