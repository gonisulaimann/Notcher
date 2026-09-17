import CryptoKit
import Foundation
import Network

/// Local-network transport for Notcher Link (macOS + iOS shared).
///
/// Discovery: Bonjour `_notcherlink._tcp`. Encryption: app-layer AES-GCM
/// (see LinkCrypto). All mutable state lives on a private serial queue;
/// owner callbacks are delivered on `callbackQueue` (main by default).
public final class LinkTransport: @unchecked Sendable {
    public struct Peer: Identifiable, Sendable {
        public var id: String { deviceID }
        public var deviceID: String
        public var deviceName: String
        public var lastSeen: Date
    }

    public var onMessage: ((LinkMessage) -> Void)?
    public var onPeersChanged: (([Peer]) -> Void)?

    private let deviceName: String
    private let deviceID: String
    private let code: () -> String
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var salt: String = LinkCrypto.randomSalt()
    private var running = false

    private final class Conn: @unchecked Sendable {
        let nw: NWConnection
        let outgoing: Bool
        var buffer = Data()
        var key: SymmetricKey?
        var authed = false
        var remoteDeviceID: String?
        var remoteName: String?
        init(nw: NWConnection, outgoing: Bool) {
            self.nw = nw
            self.outgoing = outgoing
        }
    }

    private var conns: [ObjectIdentifier: Conn] = [:]
    /// deviceID -> connection id (ready only)
    private var readyByDevice: [String: ObjectIdentifier] = [:]
    private var peers: [String: Peer] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var retryWork: [String: DispatchWorkItem] = [:]
    private var retryAttempts: [String: Int] = [:]

    public init(
        deviceName: String,
        deviceID: String,
        code: @escaping @Sendable () -> String,
        callbackQueue: DispatchQueue = .main
    ) {
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.code = code
        self.queue = DispatchQueue(label: "dev.notcher.link")
        self.callbackQueue = callbackQueue
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            salt = LinkCrypto.randomSalt()
            startListener()
            startBrowser()
            startHeartbeat()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            retryWork.values.forEach { $0.cancel() }
            retryWork.removeAll()
            browser?.cancel()
            browser = nil
            listener?.cancel()
            listener = nil
            for c in conns.values { c.nw.cancel() }
            conns.removeAll()
            readyByDevice.removeAll()
            peers.removeAll()
            emitPeers()
        }
    }

    // MARK: - Direct (loopback / test) connections

    /// Listen on 127.0.0.1 without Bonjour. Returns the bound port.
    @discardableResult
    public func listenDirect(on port: UInt16 = 0) throws -> UInt16 {
        let params = NWParameters.tcp
        let lis = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        final class Box: @unchecked Sendable { var bound: UInt16 = 0; let ready = DispatchSemaphore(value: 0) }
        let box = Box()
        lis.stateUpdateHandler = { state in
            if case .ready = state, let p = lis.port { box.bound = p.rawValue; box.ready.signal() }
            if case .failed = state { box.ready.signal() }
        }
        lis.newConnectionHandler = { [weak self] nw in self?.accept(nw, outgoing: false) }
        lis.start(queue: queue)
        _ = box.ready.wait(timeout: .now() + 5)
        listener = lis
        salt = LinkCrypto.randomSalt()
        startHeartbeat()
        running = true
        return box.bound
    }

    public func connectDirect(host: String = "127.0.0.1", port: UInt16) {
        queue.async { [self] in
            running = true
            let nw = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            dial(nw, keyHint: host + ":\(port)")
        }
    }

    /// Dial a Bonjour-resolved endpoint (used by dev tooling to reach the
    /// live app without hardcoding ports).
    public func connectToEndpoint(_ endpoint: NWEndpoint) {
        queue.async { [self] in
            running = true
            dial(NWConnection(to: endpoint, using: .tcp),
                 keyHint: String(describing: endpoint))
        }
    }

    // MARK: - Send

    public func broadcast(_ message: LinkMessage) {
        queue.async { [self] in
            guard let payload = try? LinkCodec.encode(message) else { return }
            for (id, c) in conns where c.authed {
                guard let key = c.key, let sealed = try? LinkCrypto.seal(payload, key: key) else { continue }
                sendFrame(LinkCodec.frame(sealed), on: c, id: id)
            }
        }
    }

    public var connectedPeers: [Peer] {
        queue.sync { Array(peers.values) }
    }

    // MARK: - Private: listener / browser

    private func startListener() {
        let name = "\(deviceName) \(deviceID.prefix(4))".prefix(63)
        let service = NWListener.Service(name: String(name), type: LinkProtocol.serviceType)
        do {
            let lis = try NWListener(service: service, using: NWParameters.tcp)
            lis.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state { self?.queue.async { self?.scheduleListenerRestart() }; _ = err }
            }
            lis.newConnectionHandler = { [weak self] nw in self?.queue.async { self?.accept(nw, outgoing: false) } }
            lis.start(queue: queue)
            listener = lis
        } catch {
            scheduleListenerRestart()
        }
    }

    private func scheduleListenerRestart() {
        guard running else { return }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.running, self.listener == nil else { return }
            self.startListener()
        }
        listener = nil
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: LinkProtocol.serviceType, domain: nil), using: NWParameters.tcp)
        // Strong capture is safe: stop() cancels and nils the browser,
        // breaking the transport -> browser -> handler -> transport cycle.
        browser.browseResultsChangedHandler = { [self] results, _ in
            self.queue.async { [weak self] in self?.handleBrowse(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.running else { return }
                    self.startBrowser()
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowse(_ results: Set<NWBrowser.Result>) {
        guard running else { return }
        for result in results {
            guard case .service = result.endpoint else { continue }
            let key = String(describing: result.endpoint)
            if conns.values.contains(where: { !$0.outgoing }) { /* inbound may already cover */ }
            let already = conns.values.contains { c in
                c.outgoing && String(describing: c.nw.endpoint) == key
            }
            if already { continue }
            let nw = NWConnection(to: result.endpoint, using: NWParameters.tcp)
            dial(nw, keyHint: key)
        }
    }

    // MARK: - Private: connections

    private func accept(_ nw: NWConnection, outgoing: Bool) {
        let c = Conn(nw: nw, outgoing: outgoing)
        let id = ObjectIdentifier(c)
        conns[id] = c
        nw.stateUpdateHandler = { [weak self] state in self?.connState(state, id: id) }
        nw.start(queue: queue)
    }

    private func dial(_ nw: NWConnection, keyHint: String) {
        retryWork[keyHint]?.cancel()
        accept(nw, outgoing: true)
    }

    private func connState(_ state: NWConnection.State, id: ObjectIdentifier) {
        guard let c = conns[id] else { return }
        switch state {
        case .ready:
            if c.outgoing {
                // Wait for the listener's salt frame; do nothing yet.
            } else {
                // Listener speaks first: send salt frame in the clear.
                let frame = LinkSaltFrame(salt: salt, deviceName: deviceName, deviceID: deviceID)
                if let data = try? JSONEncoder().encode(frame) {
                    sendFrame(LinkCodec.frame(data), on: c, id: id)
                }
            }
            receive(on: c, id: id)
        case .failed, .cancelled:
            drop(id)
            if c.outgoing, running {
                let hint = String(describing: c.nw.endpoint)
                // Exponential backoff per endpoint (5s → 60s cap) so a
                // wrong-code peer or a dead listener doesn't turn into a
                // permanent 5-second handshake storm on the LAN.
                let attempts = (retryAttempts[hint] ?? 0) + 1
                retryAttempts[hint] = attempts
                let delay = min(60, 5 * (1 << min(attempts - 1, 3)))
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        guard self.running else { return }
                        let nw = NWConnection(to: c.nw.endpoint, using: NWParameters.tcp)
                        self.dial(nw, keyHint: hint)
                    }
                }
                retryWork[hint]?.cancel()
                retryWork[hint] = work
                queue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
            }
        default:
            break
        }
    }

    private func receive(on c: Conn, id: ObjectIdentifier) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard self.conns[id] != nil else { return }
                if let data, !data.isEmpty {
                    c.buffer.append(data)
                    self.pumpBuffer(c, id: id)
                    self.receive(on: c, id: id)
                } else if error != nil {
                    self.drop(id)
                } else {
                    self.receive(on: c, id: id)
                }
            }
        }
    }

    private func pumpBuffer(_ c: Conn, id: ObjectIdentifier) {
        while true {
            guard c.buffer.count >= 4 else { return }
            let len = Int(LinkCodec.readLength(c.buffer.subdata(in: 0 ..< 4)))
            guard len <= 40 * 1024 * 1024 else { drop(id); return }
            guard c.buffer.count >= 4 + len else { return }
            let payload = c.buffer.subdata(in: 4 ..< 4 + len)
            c.buffer.removeSubrange(0 ..< 4 + len)
            handlePayload(payload, c: c, id: id)
            if conns[id] == nil { return } // dropped during handling
        }
    }

    private func handlePayload(_ payload: Data, c: Conn, id: ObjectIdentifier) {
        if c.key == nil {
            // Expecting salt (dialer) — listener never hits this branch since
            // it sets no key until auth arrives... but listener also receives
            // the dialer's auth first. Distinguish by trying salt decode.
            if !c.outgoing {
                // Listener: first frame from dialer must be auth (sealed).
                guard let key = try? deriveKey() else { drop(id); return }
                guard let plain = try? LinkCrypto.open(payload, key: key),
                      let auth = try? LinkCrypto.verifyAuth(plain)
                else { drop(id); return } // wrong pairing code
                if auth.deviceID == deviceID { drop(id); return } // self-connect
                c.key = key
                c.remoteDeviceID = auth.deviceID
                c.remoteName = auth.deviceName
                // Reply with our own auth.
                if let sealed = try? LinkCrypto.encodeAuth(deviceName: deviceName, deviceID: deviceID, key: key) {
                    sendFrame(LinkCodec.frame(sealed), on: c, id: id)
                }
                markReady(c, id: id)
            } else {
                // Dialer: first frame must be the salt (plaintext JSON).
                guard let saltFrame = try? JSONDecoder().decode(LinkSaltFrame.self, from: payload),
                      saltFrame.v == LinkProtocol.protocolVersion
                else { drop(id); return }
                let key = LinkCrypto.deriveKey(salt: saltFrame.salt, code: code())
                c.key = key
                c.remoteDeviceID = saltFrame.deviceID
                c.remoteName = saltFrame.deviceName
                if saltFrame.deviceID == deviceID { drop(id); return }
                if let sealed = try? LinkCrypto.encodeAuth(deviceName: deviceName, deviceID: deviceID, key: key) {
                    sendFrame(LinkCodec.frame(sealed), on: c, id: id)
                }
                // Wait for listener's auth reply before marking ready.
            }
            return
        }
        if !c.authed {
            // Dialer receiving listener's auth reply.
            guard let key = c.key,
                  let plain = try? LinkCrypto.open(payload, key: key),
                  let auth = try? LinkCrypto.verifyAuth(plain)
            else { drop(id); return }
            c.remoteDeviceID = auth.deviceID
            c.remoteName = auth.deviceName
            markReady(c, id: id)
            return
        }
        // Ready: sealed LinkMessage.
        guard let key = c.key,
              let plain = try? LinkCrypto.open(payload, key: key),
              var msg = try? LinkCodec.decode(plain)
        else { return }
        touchPeer(c)
        // Stamp sender id from the connection (not self-reported).
        msg.deviceID = c.remoteDeviceID ?? msg.deviceID
        let senderName = c.remoteName ?? msg.deviceName
        msg.deviceName = senderName
        let captured = msg
        callbackQueue.async { [weak self] in self?.onMessage?(captured) }
    }

    private func deriveKey() throws -> SymmetricKey {
        LinkCrypto.deriveKey(salt: salt, code: code())
    }

    private func markReady(_ c: Conn, id: ObjectIdentifier) {
        guard let remote = c.remoteDeviceID else { drop(id); return }
        c.authed = true
        if let existing = readyByDevice[remote], existing != id,
           let other = conns[existing]
        {
            // Deterministic dedup: exactly one side keeps incoming.
            let keepIncoming = deviceID > remote
            if c.outgoing == other.outgoing {
                drop(id); return
            }
            if keepIncoming == c.outgoing {
                drop(id); return
            } else {
                drop(existing)
            }
        }
        readyByDevice[remote] = id
        peers[remote] = Peer(deviceID: remote, deviceName: c.remoteName ?? remote, lastSeen: Date())
        // A fresh authenticated session resets backoff for every endpoint:
        // the network is healthy, any pending retries are stale.
        retryAttempts.removeAll()
        emitPeers()
        var hello = LinkMessage(kind: .hello, deviceName: deviceName, deviceID: deviceID)
        hello.battery = LinkHostState.sharedBattery()
        if let payload = try? LinkCodec.encode(hello),
           let key = c.key,
           let sealed = try? LinkCrypto.seal(payload, key: key)
        {
            sendFrame(LinkCodec.frame(sealed), on: c, id: id)
        }
    }

    private func touchPeer(_ c: Conn) {
        guard let remote = c.remoteDeviceID else { return }
        peers[remote] = Peer(deviceID: remote, deviceName: c.remoteName ?? remote, lastSeen: Date())
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let c = conns.removeValue(forKey: id) else { return }
        c.nw.cancel()
        if let remote = c.remoteDeviceID, readyByDevice[remote] == id {
            readyByDevice.removeValue(forKey: remote)
            peers.removeValue(forKey: remote)
            emitPeers()
        }
    }

    private func sendFrame(_ frame: Data, on c: Conn, id: ObjectIdentifier) {
        c.nw.send(content: frame, completion: .idempotent)
        _ = id // failed sends surface through connection state changes
    }

    // MARK: - Heartbeat / timeout

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + LinkProtocol.heartbeatInterval,
                   repeating: LinkProtocol.heartbeatInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        heartbeatTimer = t
    }

    private func tick() {
        guard running else { return }
        var hb = LinkMessage(kind: .heartbeat, deviceName: deviceName, deviceID: deviceID)
        hb.battery = LinkHostState.sharedBattery()
        broadcast(hb)
        let cutoff = Date().addingTimeInterval(-LinkProtocol.peerTimeoutInterval)
        var changed = false
        for (remote, peer) in peers where peer.lastSeen < cutoff {
            peers.removeValue(forKey: remote)
            if let id = readyByDevice.removeValue(forKey: remote) {
                conns[id]?.nw.cancel()
                conns.removeValue(forKey: id)
            }
            changed = true
        }
        if changed { emitPeers() }
    }

    private func emitPeers() {
        let snap = Array(peers.values)
        callbackQueue.async { [weak self] in self?.onPeersChanged?(snap) }
    }
}

/// Tiny hook so LinkCore can stamp battery on hello/heartbeat without
/// depending on AppKit/IOKit (set by the Mac app; iOS sets its own).
public enum LinkHostState {
    nonisolated(unsafe) public static var sharedBattery: @Sendable () -> Double? = { nil }
}
