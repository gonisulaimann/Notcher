import AppKit
import Foundation
import Network

// notcher — IslandKit command line.
//   notcher push "Building…" [--subtitle …] [--progress 0.7] [--ttl 5m]
//           [--priority low|normal|high] [--id job] [--source Chef] [--icon hammer]
//   notcher clear [--id job]
// Transport: loopback socket first (fast, streaming, replies), URL scheme
// fallback (works even if the socket is down). Exits 0 on delivery, 1
// otherwise. The island itself asks for consent on first push; this tool
// never bypasses that.

struct CLI {
    static let port: UInt16 = 17874

    static func usage() -> Never {
        fputs("usage:\n  notcher push \"title\" [--subtitle s] [--progress 0..1] [--ttl 5m|2h|90s] [--priority low|normal|high] [--id id] [--source name] [--icon symbol]\n  notcher clear [--id id]\n", stderr)
        exit(2)
    }

    static func run() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first, verb == "push" || verb == "clear" else { usage() }
        args.removeFirst()

        var positional: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--"), i + 1 < args.count {
                flags[String(a.dropFirst(2))] = args[i + 1]
                i += 2
            } else {
                positional.append(a)
                i += 1
            }
        }

        // Envelope for the socket (keys mirror the URL params).
        var payload: [String: Any] = ["op": verb == "push" ? "push" : "clear"]
        var urlComps = URLComponents()
        urlComps.scheme = "notcher"
        urlComps.host = verb == "push" ? "activity" : "clear"
        var items: [URLQueryItem] = []
        if verb == "push" {
            guard let title = positional.first, !title.isEmpty else { usage() }
            payload["title"] = title
            items.append(URLQueryItem(name: "title", value: title))
            for key in ["subtitle", "progress", "ttl", "priority", "id", "source", "icon"] {
                if let v = flags[key] {
                    payload[key] = key == "progress" ? (Double(v) ?? v) : v
                    items.append(URLQueryItem(name: key, value: v))
                }
            }
        } else if let id = flags["id"] {
            payload["id"] = id
            items.append(URLQueryItem(name: "id", value: id))
        }
        urlComps.queryItems = items.isEmpty ? nil : items

        if sendSocket(payload) { exit(0) }
        // Fallback: URL scheme (also the path when the app predates sockets).
        guard let url = urlComps.url, NSWorkspace.shared.open(url) else {
            fputs("notcher: delivery failed (socket refused, URL open failed)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    /// One JSON line + one reply line, 1.5 s budget, synchronous.
    static func sendSocket(_ payload: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var mutable = body
        mutable.append(UInt8(ascii: "\n"))
        let line = mutable
        let box = ReplyBox()
        let queue = DispatchQueue(label: "notcher.cli")
        let done = DispatchSemaphore(value: 0)
        let conn = NWConnection(host: "127.0.0.1",
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: line, completion: .contentProcessed { _ in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        if let data,
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           obj["ok"] as? Bool == true
                        {
                            box.ok = true
                        }
                        done.signal()
                        conn.cancel()
                    }
                })
            } else if case .failed = state {
                done.signal()
                conn.cancel()
            }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + 1.5)
        conn.cancel()
        return box.ok
    }

    final class ReplyBox: @unchecked Sendable {
        var ok = false
    }
}

CLI.run()
