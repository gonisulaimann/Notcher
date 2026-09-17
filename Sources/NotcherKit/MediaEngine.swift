import AppKit
import Combine

/// System-wide Now Playing via public scripting interfaces only.
///
/// - Music.app and Spotify are queried through AppleScript, and ONLY when
///   the target app is already running (we never launch a music app just to
///   ask it what is playing).
/// - Spotify's `com.spotify.client.PlaybackStateChanged` distributed
///   notification triggers an immediate repoll.
/// - Deliberately NOT using MediaRemote.framework: it is private API and
///   would break the "real product, public APIs" rule.
@MainActor
public final class MediaEngine: ObservableObject {
    @Published public private(set) var playing = false
    @Published public private(set) var title: String?
    @Published public private(set) var artist: String?
    @Published public private(set) var appName: String?

    public var onChanged: (() -> Void)?

    private var poll: Timer?
    private var lastSig = ""

    // Precompiled once: compiling AppleScript source on every 2.5s poll
    // costs ~5-15% CPU. Execution of a compiled script is cheap IPC.
    private let musicQuery: NSAppleScript? = NSAppleScript(source: """
        tell application "Music"
            try
                return {player state as string, name of current track, artist of current track}
            on error
                return {"stopped", "", ""}
            end try
        end tell
        """)
    private let spotifyQuery: NSAppleScript? = NSAppleScript(source: """
        tell application "Spotify"
            try
                return {player state as string, name of current track, artist of current track}
            on error
                return {"stopped", "", ""}
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

    // MARK: - Private

    private func setIdle() {
        let sig = "idle"
        guard sig != lastSig else { return }
        lastSig = sig
        playing = false; title = nil; artist = nil; appName = nil
        onChanged?()
    }

    private func apply(app: String, info: (playing: Bool, title: String?, artist: String?)) {
        let sig = "\(app)|\(info.playing)|\(info.title ?? "")|\(info.artist ?? "")"
        guard sig != lastSig else { return }
        lastSig = sig
        appName = app
        playing = info.playing
        title = info.title?.isEmpty == true ? nil : info.title
        artist = info.artist?.isEmpty == true ? nil : info.artist
        onChanged?()
    }

    private func applySpotify(info: [String: Any]) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        let playing = state == "playing"
        let title = info["Name"] as? String
        let artist = info["Artist"] as? String
        apply(app: "Spotify", info: (playing, title, artist))
    }

    private func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func queryMusic() -> (playing: Bool, title: String?, artist: String?)? {
        guard let desc = execute(musicQuery),
              desc.numberOfItems >= 3,
              let state = desc.atIndex(1)?.stringValue
        else { return nil }
        return (state == "playing", desc.atIndex(2)?.stringValue, desc.atIndex(3)?.stringValue)
    }

    private func querySpotify() -> (playing: Bool, title: String?, artist: String?)? {
        guard let desc = execute(spotifyQuery),
              desc.numberOfItems >= 3,
              let state = desc.atIndex(1)?.stringValue
        else { return nil }
        return (state == "playing", desc.atIndex(2)?.stringValue, desc.atIndex(3)?.stringValue)
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
