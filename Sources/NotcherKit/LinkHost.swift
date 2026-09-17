import AppKit
import Combine
import Foundation
import LinkCore

/// Mac-side owner of the Notcher Link session: presence, timers, text and
/// file handoff with the iPhone companion. Everything is user-initiated or
/// explicit state sync — no background scraping, no cloud.
@MainActor
public final class LinkHost: ObservableObject {
    @Published public private(set) var peers: [LinkTransport.Peer] = []
    @Published public private(set) var enabled = true
    @Published public private(set) var code: String = ""
    @Published public private(set) var receiving: (fileName: String, got: Int, total: Int)?
    @Published public private(set) var remoteTimer: (peer: String, remaining: Double, total: Double, label: String, updatedAt: Date)?
    /// Tray text-field drafts (view state kept here: no @State under CLT).
    @Published public var draftMessage: String = ""
    @Published public private(set) var confirmRegen = false

    public var onEvent: ((LinkEvent) -> Void)?

    public enum LinkEvent {
        case peerJoined(String)
        case peerLeft(String)
        case textReceived(String, String)   // peer, preview
        case fileReceived(String, String)  // peer, file name
        case timerStartedRemotely(String)  // peer
    }

    private var transport: LinkTransport?
    private let deviceID: String
    private let deviceName: String

    private weak var timers: TimerEngine?
    private weak var harbor: HarborStore?
    private weak var island: IslandState?

    private var incoming: [String: IncomingFile] = [:]
    private var remoteTimerExpiry: DispatchWorkItem?
    private var knownPeers = Set<String>()
    private var stateLoop: Timer?

    private struct IncomingFile {
        var name: String
        var size: Int
        var chunks: [Int: Data]
        var count: Int
    }

    public init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "link.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "link.deviceID")
        }
        deviceName = Host.current().localizedName ?? "Mac"
        if let saved = defaults.string(forKey: "link.code"), saved.count == 6 {
            code = saved
        } else {
            code = String(format: "%06d", Int.random(in: 0 ... 999_999))
            defaults.set(code, forKey: "link.code")
        }
        enabled = defaults.object(forKey: "link.enabled") as? Bool ?? true
        LinkHostState.sharedBattery = { LinkHostBatteryProvider.battery }
    }

    public func attach(timer: TimerEngine, harbor: HarborStore, island: IslandState) {
        timers = timer
        self.harbor = harbor
        self.island = island
    }

    public func start() {
        guard enabled else { return }
        // The code closure reads live defaults so rotation (regenerate)
        // takes effect on the restarted session without more plumbing.
        let t = LinkTransport(deviceName: deviceName, deviceID: deviceID, code: {
            UserDefaults.standard.string(forKey: "link.code") ?? "000000"
        })
        t.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg) }
        }
        t.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.updatePeers(peers) }
        }
        transport = t
        t.start()
    }

    public func stop() {
        transport?.stop()
        transport = nil
        stateLoop?.invalidate()
        stateLoop = nil
        peers = []
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "link.enabled")
        if on { start() } else { stop() }
    }

    public func regenerateCode() {
        code = String(format: "%06d", Int.random(in: 0 ... 999_999))
        UserDefaults.standard.set(code, forKey: "link.code")
        confirmRegen = false
        // Key rotation: restart the session so old keys die immediately.
        if enabled { stop(); start() }
    }

    public func armRegenConfirm() {
        confirmRegen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in self?.confirmRegen = false }
        }
    }

    // MARK: - Outgoing (all explicit user actions or state mirrors)

    public func sendText(_ text: String) {
        var m = LinkMessage(kind: .textPush, deviceName: deviceName, deviceID: deviceID)
        m.text = text
        transport?.broadcast(m)
    }

    public func sendFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              data.count <= LinkProtocol.maxFileBytes,
              !peers.isEmpty
        else { return }
        for m in LinkChunker.pack(data: data, fileName: url.lastPathComponent,
                                  deviceName: deviceName, deviceID: deviceID)
        {
            transport?.broadcast(m)
        }
    }

    public func broadcastTimerState() {
        guard let t = timers else { return }
        var m = LinkMessage(kind: .timerState, deviceName: deviceName, deviceID: deviceID)
        m.seconds = t.remaining
        m.total = t.total
        m.label = t.label
        transport?.broadcast(m)
        // While a local timer runs, mirrors need periodic truth (not just
        // edge transitions), so keep a slow broadcast loop alive.
        if t.isActive {
            if stateLoop == nil {
                let loop = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.broadcastTimerState() }
                }
                RunLoop.main.add(loop, forMode: .common)
                stateLoop = loop
            }
        } else {
            stateLoop?.invalidate()
            stateLoop = nil
        }
    }

    public func broadcastMedia(playing: Bool, title: String?, artist: String?) {
        var m = LinkMessage(kind: .mediaState, deviceName: deviceName, deviceID: deviceID)
        m.playing = playing
        m.mediaTitle = title
        m.mediaArtist = artist
        transport?.broadcast(m)
    }

    // MARK: - Incoming

    private func updatePeers(_ list: [LinkTransport.Peer]) {
        let ids = Set(list.map(\.deviceID))
        for p in list where !knownPeers.contains(p.deviceID) {
            onEvent?(.peerJoined(p.deviceName))
        }
        for id in knownPeers where !ids.contains(id) {
            onEvent?(.peerLeft(id))
        }
        knownPeers = ids
        peers = list
    }

    private func handle(_ msg: LinkMessage) {
        switch msg.kind {
        case .hello, .heartbeat:
            break // presence is tracked by the transport itself
        case .bye:
            break
        case .timerStart:
            if let s = msg.seconds {
                timers?.start(seconds: s, label: msg.label ?? "")
                timers?.label = msg.label ?? ""
                onEvent?(.timerStartedRemotely(msg.deviceName))
            }
        case .timerState:
            if let s = msg.seconds {
                remoteTimerExpiry?.cancel()
                remoteTimer = (msg.deviceName, s, msg.total ?? s, msg.label ?? "", Date())
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in self?.remoteTimer = nil }
                }
                remoteTimerExpiry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
            }
        case .timerCancel:
            if remoteTimer?.peer == msg.deviceName { remoteTimer = nil }
            if timers?.isActive == true { timers?.cancel() }
        case .textPush:
            if let text = msg.text, !text.isEmpty { saveText(text, from: msg.deviceName) }
        case .fileOffer:
            if let name = msg.fileName, let size = msg.fileSize, let count = msg.chunkCount,
               size <= LinkProtocol.maxFileBytes
            {
                incoming[msg.deviceID + name] = IncomingFile(name: name, size: size, chunks: [:], count: count)
                receiving = (name, 0, count)
            }
        case .fileChunk:
            guard let name = msg.fileName, let idx = msg.chunkIndex,
                  let b64 = msg.base64, let data = Data(base64Encoded: b64)
            else { return }
            let key = msg.deviceID + name
            if var inc = incoming[key] {
                inc.chunks[idx] = data
                incoming[key] = inc
                receiving = (name, inc.chunks.count, inc.count)
            }
        case .fileDone:
            if let name = msg.fileName { finishFile(name: name, from: msg.deviceName, deviceID: msg.deviceID) }
        case .battery, .mediaState:
            break
        }
    }

    private func inboxDir() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Notcher Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueURL(in dir: URL, name: String) -> URL {
        // Anchor on the ORIGINAL stem: deriving each candidate from the
        // previous one accumulates suffixes ("a 2 3.txt").
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let suffixed = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            url = dir.appendingPathComponent(suffixed)
            n += 1
            if n > 100 { break }
        }
        return url
    }

    private func saveText(_ text: String, from peer: String) {
        let url = uniqueURL(in: inboxDir(), name: "Note from \(peer).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        harbor?.add(urls: [url])
        onEvent?(.textReceived(peer, String(text.prefix(80))))
    }

    private func finishFile(name: String, from peer: String, deviceID: String) {
        defer { receiving = nil }
        // Exact device+name match: two iPhones sending "photo.jpg" must not
        // reassemble into each other.
        let key = deviceID + name
        guard let entry = incoming[key] else { return }
        var data = Data()
        data.reserveCapacity(entry.size)
        for i in 0 ..< entry.count {
            guard let c = entry.chunks[i] else {
                incoming.removeValue(forKey: key)
                return // incomplete: drop rather than deliver a corrupt file
            }
            data.append(c)
        }
        incoming.removeValue(forKey: key)
        guard data.count <= LinkProtocol.maxFileBytes else { return }
        let url = uniqueURL(in: inboxDir(), name: name)
        do {
            try data.write(to: url, options: .atomic)
            harbor?.add(urls: [url])
            onEvent?(.fileReceived(peer, name))
        } catch {
            onEvent?(.fileReceived(peer, name + " (save failed)"))
        }
    }
}
