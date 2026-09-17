import Foundation

/// Dev-only transition/window log. Enabled with `NOTCHER_DEBUG=1` in the
/// environment; silent in normal runs. Used to hunt the flicker class of
/// bugs: every state transition and every window operation is timestamped.
public enum IslandDebug {
    nonisolated(unsafe) private static let enabled: Bool = {
        ProcessInfo.processInfo.environment["NOTCHER_DEBUG"] == "1"
    }()

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let msg = message()
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)
        NSLog("[notcher] %7.3f %@", t, msg)
    }
}
