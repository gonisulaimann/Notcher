import Combine
import Foundation
import LinkCore
import UIKit

/// iPhone-side owner of the Notcher Link session.
///
/// Mirrors LinkHost's role on the Mac: presence, remote timer control +
/// mirror, text/file exchange. No iCloud, no accounts, no background
/// scraping — the app only syncs while open (iOS suspends Bonjour when
/// backgrounded, which the Mac surfaces as "iPhone left").
@MainActor
public final class LinkPeer: ObservableObject {
    public struct ReceivedText: Identifiable {
        public var id = UUID()
        public var peer: String
        public var text: String
        public var date = Date()
    }

    public struct ReceivedFile: Identifiable {
        public var id = UUID()
        public var peer: String
        public var name: String
        public var url: URL
        public var date = Date()
    }

    public struct MacTimer {
        public var remaining: Double
        public var total: Double
        public var label: String
        public var updatedAt = Date()
        public var liveRemaining: Double {
            max(0, remaining - Date().timeIntervalSince(updatedAt))
        }
        public var isFresh: Bool {
            Date().timeIntervalSince(updatedAt) < 12
        }
    }

    @Published public private(set) var peers: [LinkTransport.Peer] = []
    @Published public private(set) var running = false
    @Published public var code: String = ""
    @Published public private(set) var macTimer: MacTimer?
    @Published public private(set) var macMedia: (title: String?, artist: String?, playing: Bool)?
    @Published public private(set) var texts: [ReceivedText] = []
    @Published public private(set) var files: [ReceivedFile] = []
    @Published public private(set) var receiving: (fileName: String, got: Int, total: Int)?
    /// When the session has been up a while with no peers, the UI should say
    /// so explicitly (wrong code vs. different Wi-Fi is otherwise silent).
    public var helpNeeded: Bool {
        running && peers.isEmpty && startedAt.map { Date().timeIntervalSince($0) > 12 } ?? false
    }

    private var transport: LinkTransport?
    private let deviceID: String
    private let deviceName: String
    private var incoming: [String: IncomingFile] = [:]
    private var ticker: Timer?
    private var startedAt: Date?

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
            deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            defaults.set(deviceID, forKey: "link.deviceID")
        }
        deviceName = UIDevice.current.name
        code = defaults.string(forKey: "link.code") ?? ""
        UIDevice.current.isBatteryMonitoringEnabled = true
        LinkHostState.sharedBattery = { [weak self] in
            Task { @MainActor in _ = self }
            guard UserDefaults.standard.object(forKey: "link.shareBattery") as? Bool ?? true else { return nil }
            let level = UIDevice.current.batteryLevel
            return level >= 0 ? Double(level) : nil
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: - Session

    public func start() {
        guard !code.isEmpty else { return } // need the Mac's pairing code first
        UserDefaults.standard.set(code, forKey: "link.code")
        let t = LinkTransport(deviceName: deviceName, deviceID: deviceID, code: {
            UserDefaults.standard.string(forKey: "link.code") ?? ""
        })
        t.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg) }
        }
        t.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.peers = peers }
        }
        transport = t
        running = true
        startedAt = Date()
        t.start()
    }

    public func stop() {
        transport?.stop()
        transport = nil
        running = false
        startedAt = nil
        peers = []
    }

    public func reconnect() {
        stop()
        start()
    }

    // MARK: - Outgoing

    public func sendText(_ text: String) {
        var m = LinkMessage(kind: .textPush, deviceName: deviceName, deviceID: deviceID)
        m.text = text
        transport?.broadcast(m)
    }

    public func sendFile(name: String, data: Data) {
        guard data.count <= LinkProtocol.maxFileBytes else { return }
        for m in LinkChunker.pack(data: data, fileName: name,
                                  deviceName: deviceName, deviceID: deviceID)
        {
            transport?.broadcast(m)
        }
    }

    public func startMacTimer(seconds: TimeInterval, label: String) {
        var m = LinkMessage(kind: .timerStart, deviceName: deviceName, deviceID: deviceID)
        m.seconds = seconds
        m.label = label
        transport?.broadcast(m)
    }

    public func cancelMacTimer() {
        let m = LinkMessage(kind: .timerCancel, deviceName: deviceName, deviceID: deviceID)
        transport?.broadcast(m)
    }

    // MARK: - Incoming

    private func tick() {
        // Expire a stale Mac-timer mirror so the UI never shows a frozen clock.
        if let t = macTimer, !t.isFresh { macTimer = nil }
    }

    private func handle(_ msg: LinkMessage) {
        switch msg.kind {
        case .hello, .heartbeat, .bye:
            break
        case .timerStart, .timerCancel:
            break // addressed to the Mac; ignore our own echo
        case .timerState:
            if let s = msg.seconds {
                macTimer = MacTimer(remaining: s, total: msg.total ?? s, label: msg.label ?? "")
            }
        case .textPush:
            if let text = msg.text, !text.isEmpty {
                texts.insert(ReceivedText(peer: msg.deviceName, text: text), at: 0)
                texts = Array(texts.prefix(20))
            }
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
        case .battery:
            break
        case .mediaState:
            macMedia = (msg.mediaTitle, msg.mediaArtist, msg.playing ?? false)
        }
    }

    private func inboxDir() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func finishFile(name: String, from peer: String, deviceID: String) {
        defer { receiving = nil }
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
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = inboxDir().appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let suffixed = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            url = inboxDir().appendingPathComponent(suffixed)
            n += 1
            if n > 100 { return }
        }
        do {
            try data.write(to: url, options: .atomic)
            files.insert(ReceivedFile(peer: peer, name: name, url: url), at: 0)
            files = Array(files.prefix(20))
        } catch { /* surface as a missing file: nothing to show */ }
    }
}
