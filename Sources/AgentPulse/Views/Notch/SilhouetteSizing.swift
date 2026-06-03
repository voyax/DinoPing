import AgentPulseCore
import CoreGraphics

/// Single source of truth for the visible silhouette dimensions.
///
/// Both `NotchContentView` (which draws the shape) and `NotchPanel.currentHitTestRect`
/// (which determines the click-through region) consult this. If they ever
/// drift apart you get the "invisible hot zone" bug — the click-blocking
/// area extends past the visible black silhouette.
///
/// Dimensions come from the design spec (`design_handoff_agentpulse`):
/// - Compact pill: notch core 200 wide, height 32 (matches physical MBP
///   notch). Pill grows up to 280 wide based on content.
/// - Expanded panel: 410 × up to 380.
///
/// Top corners are CONCAVE shoulders (curve outward to meet the menu bar).
/// `shoulder` is how far the shoulder protrudes past the visible body.
enum SilhouetteSizing {
    // MARK: - Design constants (do not change without re-checking spec)

    static let notchCoreWidth: CGFloat = 200
    static let notchCoreHeight: CGFloat = 32
    static let pillMaxWidth: CGFloat = 280

    static let expandedWidth: CGFloat = 410
    static let expandedMaxHeight: CGFloat = 380
    static let expandedMinHeight: CGFloat = 120

    /// Per-card visual height including the 6pt gap between cards (used by
    /// expandedHeight to keep the silhouette tight to the actual content).
    static let sessionCardHeight: CGFloat = 100
    static let permissionCardHeight: CGFloat = 160
    static let emptyStateContribution: CGFloat = 50

    /// Header (10+8 pad + 12pt title + divider) + footer (7×2 + 10pt).
    static let expandedHeaderHeight: CGFloat = 36
    static let expandedFooterHeight: CGFloat = 28

    // MARK: - Non-notch screens (external displays without a physical notch)

    /// On screens without a real notch we still float a pill near the top,
    /// but it's freestanding (no concave shoulders against the menu bar).
    static let nonNotchCompactWidth: CGFloat = 200
    static let nonNotchCompactHeight: CGFloat = 30
    static let nonNotchExpandedHeight: CGFloat = 220
    static let nonNotchExpandedWidth: CGFloat = 380

    // MARK: - Shape parameters

    /// How far the concave top-corner shoulders extend past the body sides.
    /// Larger = more pronounced "S-curve" into the menu bar.
    static func shoulder(state: NotchDisplayState, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return 0 }   // free-floating pill, no shoulders
        return state == .expanded ? 10 : 8
    }

    /// Radius of the bottom convex corners.
    static func bottomRadius(state: NotchDisplayState, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return state == .expanded ? 18 : 12 }
        return state == .expanded ? 22 : 12
    }

    // MARK: - Size

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
            // Pill grows past the physical notch a bit to fit "N waiting"
            // text + dino + chevron. 60pt past notch is enough at the
            // longest sensible label.
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
        let header = expandedHeaderHeight
        let footer = expandedFooterHeight
        let total = topInset + header + permsHeight + dividerHeight + sessionsHeight + footer + bottomPad
        return min(max(total, expandedMinHeight), expandedMaxHeight)
    }
}
