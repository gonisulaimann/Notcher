import AppKit

/// Resolves the physical notch rect for a screen using only public APIs.
///
/// On notch Macs (macOS 12+), `safeAreaInsets.top > 0` and the menu bar is
/// split into `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; the notch is
/// the gap between them. On all other displays we report `hasNotch = false`
/// and callers fall back to a centered floating capsule.
public struct NotchGeometry {
    public struct Layout {
        /// Width of the camera housing in points (0 when no notch).
        public var notchWidth: CGFloat
        /// Height of the menu bar / safe area at the top.
        public var topInset: CGFloat
        public var hasNotch: Bool
        /// Global screen-coordinate rect of the housing itself.
        public var housingRect: CGRect
    }

    public static func layout(for screen: NSScreen) -> Layout {
        if #available(macOS 12.0, *) {
            let insets = screen.safeAreaInsets
            if insets.top > 0,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea
            {
                let width = max(0, right.minX - left.maxX)
                let f = screen.frame
                // Housing occupies the top `insets.top` points, horizontally
                // between the two auxiliary areas.
                let housing = CGRect(
                    x: f.minX + (left.maxX - f.minX),
                    y: f.maxY - insets.top,
                    width: width,
                    height: insets.top
                )
                return Layout(notchWidth: width, topInset: insets.top, hasNotch: true, housingRect: housing)
            }
        }
        let bar = NSStatusBar.system.thickness
        let f = screen.frame
        return Layout(
            notchWidth: 0, topInset: bar, hasNotch: false,
            housingRect: CGRect(x: f.midX - 110, y: f.maxY - bar, width: 220, height: bar)
        )
    }
}
