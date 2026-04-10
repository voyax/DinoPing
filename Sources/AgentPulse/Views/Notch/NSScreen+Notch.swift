import AppKit

extension NSScreen {
    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    var notchSize: CGSize {
        guard hasNotch,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            let menubarHeight = frame.maxY - visibleFrame.maxY
            return CGSize(width: 220, height: max(menubarHeight, 24))
        }
        return CGSize(
            width: frame.width - left.width - right.width,
            height: safeAreaInsets.top
        )
    }

    /// Find the best screen for the notch overlay.
    /// Priority: notch screen > main screen > first screen.
    static var notchScreen: NSScreen? {
        screens.first { $0.hasNotch } ?? main ?? screens.first
    }
}
