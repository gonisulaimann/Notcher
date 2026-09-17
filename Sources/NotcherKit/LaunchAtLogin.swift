import Foundation
import ServiceManagement

/// Launch-at-login via the public SMAppService API (macOS 13+).
public enum LaunchAtLogin {
    public static var enabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
    }

    public static func set(_ on: Bool) throws {
        if #available(macOS 13.0, *) {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
