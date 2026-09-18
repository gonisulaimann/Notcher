import SwiftUI

/// The island's accent system: one hue per surface, used sparingly — an
/// accent is a signature, not a decoration. Every tint is tuned to read on
/// dark glass at small sizes and to pair with the white type ramp.
public enum IslandPalette {
    /// Timers: the classic focus amber.
    public static let timer = Color(red: 1.00, green: 0.62, blue: 0.20)
    /// Transfers & Harbor: growth green.
    public static let transfer = Color(red: 0.32, green: 0.85, blue: 0.48)
    /// Media: the now-playing rose.
    public static let media = Color(red: 1.00, green: 0.42, blue: 0.58)
    /// Third-party waterline activities: reserved teal (deliberately apart
    /// from every first-party accent so external content is always
    /// distinguishable at a glance).
    public static let external = Color(red: 0.28, green: 0.80, blue: 0.82)
    /// Clipboard: quiet indigo.
    public static let clipboard = Color(red: 0.58, green: 0.62, blue: 0.95)
}
