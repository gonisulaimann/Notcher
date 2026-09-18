import Foundation

/// First-run experience decision. Pure so probes can assert the whole matrix:
/// a translocated launch (running from the disk image under Gatekeeper
/// App Translocation) always guides toward /Applications, even on repeat
/// launches; a normal first launch gets the Godmode overture once;
/// afterwards, silence.
public enum FirstRun {
    public enum Action: Equatable, Sendable {
        case overture
        case translocatedTray
    }

    public static func plan(translocated: Bool, didRun: Bool) -> Action? {
        if translocated { return .translocatedTray }
        if !didRun { return .overture }
        return nil
    }

    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("AppTranslocation")
    }

    public static let didRunKey = "didFirstRunV1"
    /// Godmode watermark: fresh key so the overture plays exactly once per
    /// install lineage — including for upgraders (one delightful moment,
    /// skippable, never repeated). The V1 key is retired, left unread.
    public static let overtureKey = "didFirstRunV2"
}
