import Foundation

/// First-run experience decision. Pure so probes can assert the whole matrix:
/// a translocated launch (running from the disk image under Gatekeeper
/// App Translocation) always guides toward /Applications, even on repeat
/// launches; a normal first launch gets one welcome; afterwards, silence.
public enum FirstRun {
    public enum Action: Equatable, Sendable {
        case welcomeTray
        case translocatedTray
    }

    public static func plan(translocated: Bool, didRun: Bool) -> Action? {
        if translocated { return .translocatedTray }
        if !didRun { return .welcomeTray }
        return nil
    }

    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("AppTranslocation")
    }

    public static let didRunKey = "didFirstRunV1"
}
