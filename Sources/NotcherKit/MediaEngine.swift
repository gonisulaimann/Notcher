import AppKit
import Combine

/// System-wide Now Playing via public scripting interfaces only.
///
/// - Music.app and Spotify are queried through AppleScript, and ONLY when
///   the target app is already running (we never launch a music app just to
///   ask it what is playing).
/// - Spotify's `com.spotify.client.PlaybackStateChanged` distributed
///   notification triggers an immediate repoll.
/// - Artwork: Spotify exposes `artwork url of current track` (fetched async
///   and cached by the view layer); Music exposes `raw data of artwork 1` as
///   a 'tdta' Apple Event descriptor, decodable straight to NSImage. Image
///   data rides a ~1 MB Apple Event, so it is fetched ONLY when the track
///   changes — the 2.5 s poll carries metadata only.
/// - Position/progress: polled with the track state; the UI interpolates
///   between polls (truth ~every 2.5 s), like the mirrored timer.
/// - Deliberately NOT using MediaRemote.framework: it is private API and
///   would break the "real product, public APIs" rule.
@MainActor
public final class MediaEngine: ObservableObject {
    @Published public private(set) var playing = false
    @Published public private(set) var title: String?
    @Published public private(set) var artist: String?
    @Published public private(set) var appName: String?
    @Published public private(set) var artworkURL: URL?
    @Published public private(set) var artworkData: Data?
    /// Track duration in seconds (nil when unknown).
    @Published public private(set) var duration: Double?
    /// Last observed playhead position (seconds) at `positionAt`.
    @Published public private(set) var position: Double = 0
    @Published public private(set) var positionAt: Date = .distantPast

    public var onChanged: (() -> Void)?

    private var poll: Timer?
    private var lastSig = ""
    /// (app, title) of the last artwork fetch — dedupes the heavy query.
    private var lastArtworkKey = ""

    // Precompiled once: compiling AppleScript source on every 2.5s poll
    // costs ~5-15% CPU. Execution of a compiled script is cheap IPC.
    private let musicQuery: NSAppleScript? = NSAppleScript(source: """
        tell application "Music"
            try
                return {player state as string, name of current track, artist of current track, player position as string, duration of current track as string}
            on error
                return {"stopped", "", "", "", ""}
            end try
        end tell
        """)
    private let musicArtQuery: NSAppleScript? = NSAppleScript(source: """
        tell application "Music"
            try
                return raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """)
    private let spotifyQuery: NSAppleScript? = NSAppleScript(source: """
        tell application "Spotify"
            try
                return {player state as string, name of current track, artist of current track, artwork url of current track, player position as string, duration of current track as string}
            on error
                return {"stopped", "", "", "", "", ""}
            end try
        end tell
        """)

    public init() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyChanged(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
        refresh()
    }

    @objc private func spotifyChanged(_ note: Notification) {
        // Spotify already tells us the state in userInfo; still repoll once
        // so Music/Spotify precedence stays consistent.
        refresh()
        if let info = note.userInfo as? [String: Any] {
            applySpotify(info: info)
        }
    }

    public func refresh() {
        if isRunning("com.apple.Music"), let info = queryMusic() {
            apply(app: "Music", info: info)
            return
        }
        if isRunning("com.spotify.client"), let info = querySpotify() {
            apply(app: "Spotify", info: info)
            return
        }
        setIdle()
    }

    // MARK: - Controls (public scripting; prompts for Automation permission)

    public func playPause() {
        guard let bundle = currentBundle else { return }
        let app = bundle == "com.spotify.client" ? "\"Spotify\"" : "\"Music\""
        _ = runScript(source: "tell application \(app) to playpause")
        refresh()
    }
    public func next() {
        guard let bundle = currentBundle else { return }
        let app = bundle == "com.spotify.client" ? "\"Spotify\"" : "\"Music\""
        _ = runScript(source: "tell application \(app) to next track"); refresh()
    }
    public func previous() {
        guard let bundle = currentBundle else { return }
        let app = bundle == "com.spotify.client" ? "\"Spotify\"" : "\"Music\""
        _ = runScript(source: "tell application \(app) to previous track"); refresh()
    }

    private var currentBundle: String? {
        appName == "Spotify" ? "com.spotify.client" : (appName == "Music" ? "com.apple.Music" : nil)
    }

    // MARK: - Progress (extrapolated between polls)

    /// Live playhead: last truth + wall clock since, clamped to duration.
    public var livePosition: Double {
        let p = position + Date().timeIntervalSince(positionAt)
        if let d = duration { return min(p, d) }
        return max(0, p)
    }

    public var progressFraction: Double {
        guard let d = duration, d > 0 else { return 0 }
        return min(1, max(0, livePosition / d))
    }

    public static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public var positionText: String { Self.mmss(livePosition) }
    public var durationText: String { duration.map(Self.mmss) ?? "0:00" }

    // MARK: - Private

    private struct TrackInfo {
        var playing: Bool
        var title: String?
        var artist: String?
        var artworkURL: URL?
        var artworkData: Data?
        var position: Double?
        var duration: Double?
    }

    private func setIdle() {
        let sig = "idle"
        guard sig != lastSig else { return }
        lastSig = sig
        playing = false; title = nil; artist = nil; appName = nil
        artworkURL = nil; artworkData = nil; duration = nil
        position = 0; positionAt = .distantPast
        onChanged?()
    }

    private func apply(app: String, info: TrackInfo) {
        let sig = "\(app)|\(info.playing)|\(info.title ?? "")|\(info.artist ?? "")|\(info.artworkURL?.absoluteString ?? "")|\(info.artworkData?.count ?? 0)|\(info.duration ?? 0)"
        guard sig != lastSig else {
            // Same track: keep the playhead truth ticking forward.
            if let p = info.position {
                position = p
                positionAt = Date()
            }
            return
        }
        lastSig = sig
        appName = app
        playing = info.playing
        title = info.title?.isEmpty == true ? nil : info.title
        artist = info.artist?.isEmpty == true ? nil : info.artist
        artworkURL = info.artworkURL
        artworkData = info.artworkData
        duration = info.duration
        position = info.position ?? 0
        positionAt = Date()
        onChanged?()
    }

    private func applySpotify(info: [String: Any]) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        apply(app: "Spotify", info: TrackInfo(playing: state == "playing",
                                              title: info["Name"] as? String,
                                              artist: info["Artist"] as? String,
                                              artworkURL: nil, artworkData: nil,
                                              position: nil, duration: nil))
    }

    private func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func queryMusic() -> TrackInfo? {
        guard let desc = execute(musicQuery), desc.numberOfItems >= 5 else { return nil }
        let state = desc.atIndex(1)?.stringValue ?? "stopped"
        let title = desc.atIndex(2)?.stringValue
        let pos = Double(desc.atIndex(4)?.stringValue ?? "") ?? nil
        let dur = Double(desc.atIndex(5)?.stringValue ?? "") ?? nil
        return TrackInfo(playing: state == "playing",
                         title: title,
                         artist: desc.atIndex(3)?.stringValue,
                         artworkURL: nil,
                         artworkData: musicArtworkIfChanged(title: title),
                         position: pos, duration: dur)
    }

    /// Heavy query, deduped on (app, title): nil when nothing changed.
    private func musicArtworkIfChanged(title: String?) -> Data? {
        let key = "Music|\(title ?? "")"
        guard key != lastArtworkKey else { return nil }
        lastArtworkKey = key
        guard let art = execute(musicArtQuery), art.descriptorType == 0x74647461 else {
            return nil
        }
        return art.data
    }

    private func querySpotify() -> TrackInfo? {
        guard let desc = execute(spotifyQuery), desc.numberOfItems >= 6 else { return nil }
        let state = desc.atIndex(1)?.stringValue ?? "stopped"
        let pos = Double(desc.atIndex(5)?.stringValue ?? "") ?? nil
        let dur = Double(desc.atIndex(6)?.stringValue ?? "") ?? nil
        return TrackInfo(playing: state == "playing",
                         title: desc.atIndex(2)?.stringValue,
                         artist: desc.atIndex(3)?.stringValue,
                         artworkURL: desc.atIndex(4)?.stringValue.flatMap(URL.init(string:)),
                         artworkData: nil,
                         position: pos, duration: dur)
    }

    @discardableResult
    private func execute(_ script: NSAppleScript?) -> NSAppleEventDescriptor? {
        guard let script else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result
    }

    @discardableResult
    private func runScript(source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result
    }
}
