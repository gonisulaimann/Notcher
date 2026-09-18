import Foundation
import Network

/// IslandKit v2 — loopback streaming socket. The app listens on 127.0.0.1
/// ONLY (constitutional: no LAN exposure for the control plane; the iPhone
/// link is a separate, pairing-gated transport). Scripts stream newline-
/// delimited JSON envelopes; each line gets a JSON reply. Malformed lines
/// get `{"ok":false}` — never a crash, never a disconnect.
///
/// Envelope: {"op":"push","id":"job","source":"Chef","title":"…",
///   "subtitle":"…","progress":0.7,"priority":"high","icon":"hammer",
///   "ttl":300}  |  {"op":"clear","id":"job"}  |  {"op":"clear"}
/// Reply: {"ok":true,"decision":"shown"} (decision mirrors the store).
public final class SocketServer: @unchecked Sendable {
    public static let port: UInt16 = 17874

    public enum Intent: Sendable {
        case push(ExternalActivity)
        case clearID(String)       // already sender-namespaced
        case clearSender(String)   // prefix: everything from one sender
    }

    /// Single intake: the coordinator applies policy (consent included —
    /// socket pushes go through the exact same submit() as URL pushes).
    public var onIntent: ((Intent) -> Void)?

    private let queue = DispatchQueue(label: "dev.notcher.socket")
    private var listener: NWListener?
    private var running = false

    public init() {}

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            do {
                let lis = try NWListener(using: params,
                                         on: NWEndpoint.Port(rawValue: Self.port)!)
                lis.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        // Port busy (or stack hiccup): the URL scheme remains
                        // the working path, so this degrades silently.
                        self?.queue.async { self?.running = false }
                    }
                }
                lis.newConnectionHandler = { [weak self] nw in
                    self?.accept(nw)
                }
                lis.start(queue: queue)
                listener = lis
            } catch {
                running = false
            }
        }
    }

    public func stop() {
        queue.sync {
            running = false
            listener?.cancel()
            listener = nil
        }
    }

    public var isRunning: Bool {
        queue.sync { running && listener != nil }
    }

    // MARK: - Private

    private final class Peer: @unchecked Sendable {
        var buffer = Data()
    }

    private func accept(_ nw: NWConnection) {
        let peer = Peer()
        nw.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive(nw, peer) }
        }
        nw.start(queue: queue)
    }

    private func receive(_ nw: NWConnection, _ peer: Peer) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isDone, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(data)
                self.pump(nw, peer)
            }
            if isDone {
                nw.cancel()
            } else {
                self.receive(nw, peer)
            }
        }
    }

    private func pump(_ nw: NWConnection, _ peer: Peer) {
        while let nl = peer.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = peer.buffer[..<nl]
            peer.buffer.removeSubrange(...nl)
            handleLine(Data(line), nw)
        }
        if peer.buffer.count > 1024 * 1024 {
            peer.buffer.removeAll() // garbage without newline: drop, stay up
        }
    }

    private struct Envelope: Decodable {
        var op: String
        var id: String?
        var source: String?
        var title: String?
        var subtitle: String?
        var progress: Double?
        var priority: String?
        var icon: String?
        var ttl: Double?
    }

    private func handleLine(_ data: Data, _ nw: NWConnection) {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            send(nw, #"{"ok":false}"# + "\n")
            return
        }
        switch env.op {
        case "clear":
            let source = (env.source?.isEmpty == false) ? env.source! : "socket"
            if let id = env.id, !id.isEmpty {
                onIntent?(.clearID("source:" + source + ":" + id))
            } else {
                onIntent?(.clearSender("source:" + source + ":"))
            }
            send(nw, #"{"ok":true}"# + "\n")
        case "push":
            guard let title = env.title, !title.isEmpty else {
                send(nw, #"{"ok":false}"# + "\n")
                return
            }
            let source = (env.source?.isEmpty == false) ? env.source! : "socket"
            let rawID = (env.id?.isEmpty == false) ? env.id! : UUID().uuidString
            let priority = env.priority.flatMap(ExternalActivity.Priority.init(rawValue:)) ?? .normal
            let activity = ExternalActivity(
                id: "source:" + source + ":" + rawID,
                source: source,
                title: title,
                subtitle: env.subtitle,
                progress: env.progress,
                priority: priority,
                icon: Self.sanitizedIcon(env.icon),
                ttl: env.ttl ?? ExternalActivity.defaultTTL)
            onIntent?(.push(activity))
            send(nw, #"{"ok":true,"decision":"accepted"}"# + "\n")
        default:
            send(nw, #"{"ok":false}"# + "\n")
        }
    }

    private static func sanitizedIcon(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." })
        else { return "app.badge" }
        return raw
    }

    private func send(_ nw: NWConnection, _ text: String) {
        nw.send(content: Data(text.utf8), completion: .idempotent)
    }
}
