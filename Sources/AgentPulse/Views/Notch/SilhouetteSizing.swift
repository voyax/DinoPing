import AgentPulseCore
import CoreGraphics

/// Single source of truth for the visible silhouette dimensions.
///
/// Both `NotchContentView` (which draws the shape) and `NotchPanel.currentHitTestRect`
/// (which determines the click-through region) consult this. If they ever
/// drift apart you get the "invisible hot zone" bug — the click-blocking
/// area extends past the visible black silhouette.
enum SilhouetteSizing {
    static let expandedMaxHeight: CGFloat = 380
    static let expandedMinHeight: CGFloat = 120
    static let expandedWidth: CGFloat = 410
    static let nonNotchExpandedHeight: CGFloat = 220
    static let nonNotchExpandedWidth: CGFloat = 380
    /// Tight fit around the compact pill text on non-notch screens. Earlier
    /// 220×32 (matching the assumed notch size) felt too forgiving — the
    /// user perceives a ~70pt wide text and is annoyed when hovering 60pt
    /// to the side already triggers expand.
    static let nonNotchCompactWidth: CGFloat = 140
    static let nonNotchCompactHeight: CGFloat = 30

    /// Per-card visual height including the 6pt gap between cards.
    static let sessionCardHeight: CGFloat = 100
    static let permissionCardHeight: CGFloat = 160
    static let emptyStateContribution: CGFloat = 50

    static func size(
        state: NotchDisplayState,
        hasNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        sessionCount: Int,
        permissionCount: Int
    ) -> CGSize {
        switch state {
        case .dormant:
            return hasNotch
                ? CGSize(width: notchWidth, height: notchHeight)
                : CGSize(width: nonNotchCompactWidth, height: nonNotchCompactHeight)
        case .compact:
            return hasNotch
                ? CGSize(width: notchWidth + 60, height: notchHeight + 16)
                : CGSize(width: nonNotchCompactWidth, height: nonNotchCompactHeight)
        case .expanded:
            let height = expandedHeight(
                hasNotch: hasNotch,
                notchHeight: notchHeight,
                sessionCount: sessionCount,
                permissionCount: permissionCount
            )
            let width = hasNotch ? expandedWidth : nonNotchExpandedWidth
            return CGSize(width: width, height: height)
        }
    }

    /// Animatable shape parameters — single source of truth consumed by both
    /// NotchContentView (drawing) and NotchPanel (hit-testing).
    static func topRadius(state: NotchDisplayState, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return state == .expanded ? 18 : 12 }
        return state == .expanded ? 22 : 6
    }

    static func bottomRadius(state: NotchDisplayState, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return state == .expanded ? 18 : 12 }
        return state == .expanded ? 36 : 20
    }

    private static func expandedHeight(
        hasNotch: Bool,
        notchHeight: CGFloat,
        sessionCount: Int,
        permissionCount: Int
    ) -> CGFloat {
        if permissionCount == 0 && sessionCount == 0 {
            return expandedMinHeight + emptyStateContribution
        }
        let topInset: CGFloat = (hasNotch ? notchHeight : 8) + 4
        let bottomPad: CGFloat = 14
        let permsHeight = CGFloat(permissionCount) * permissionCardHeight
        let dividerHeight: CGFloat = (permissionCount > 0 && sessionCount > 0) ? 8 : 0
        let sessionsHeight = CGFloat(sessionCount) * sessionCardHeight
        let total = topInset + permsHeight + dividerHeight + sessionsHeight + bottomPad
        return min(max(total, expandedMinHeight), expandedMaxHeight)
    }
}
