import AppKit
import Foundation

// notcher — IslandKit command line.
//   notcher push "Building…" [--subtitle …] [--progress 0.7] [--ttl 5m]
//           [--priority low|normal|high] [--id job] [--source Chef] [--icon hammer]
//   notcher clear [--id job]
// Exits 0 when the URL was handed to the OS, 1 otherwise. The island itself
// asks for consent on first push; this tool never bypasses that.

struct CLI {
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

        var comps = URLComponents()
        comps.scheme = "notcher"
        comps.host = verb == "push" ? "activity" : "clear"
        var items: [URLQueryItem] = []
        if verb == "push" {
            guard let title = positional.first, !title.isEmpty else { usage() }
            items.append(URLQueryItem(name: "title", value: title))
            for key in ["subtitle", "progress", "ttl", "priority", "id", "source", "icon"] {
                if let v = flags[key] { items.append(URLQueryItem(name: key, value: v)) }
            }
        } else if let id = flags["id"] {
            items.append(URLQueryItem(name: "id", value: id))
        }
        comps.queryItems = items.isEmpty ? nil : items
        guard let url = comps.url else { usage() }
        if NSWorkspace.shared.open(url) {
            exit(0)
        } else {
            fputs("notcher: could not open \(url.absoluteString)\n", stderr)
            exit(1)
        }
    }
}

CLI.run()
