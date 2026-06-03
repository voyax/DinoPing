import SwiftUI

/// macOS "Dynamic-Island-on-Mac" silhouette: a rounded body whose top
/// corners curve CONCAVELY *outward* past the frame, so the silhouette
/// appears to flow seamlessly into the menu bar.
///
/// Geometry (the body is `rect`; shoulders extend `shoulder` pixels past
/// the frame on each side):
/// ```
///     menu bar (y = 0)
///     ────────╮          ╭────────
///             ╲          ╱
///              ╲        ╱           ← concave shoulders curve outward
///   x = -s →   ▓▓▓▓▓▓▓▓▓▓   ← x = w+s
///              ▓ body  ▓
///              ▓▓▓▓▓▓▓▓
///                ╲___╱            ← bottom convex corners
/// ```
///
/// Because the path extends past the frame, place the shape inside a
/// container that does NOT clip (no `.clipShape` on the parent). When
/// you DO want to clip content to this silhouette, the clipShape itself
/// uses the same path — the overhang is intentional and consistent on
/// both sides.
///
/// - `bottomRadius` controls the bottom-corner roundness (12 compact pill,
///   22 expanded card).
/// - `shoulder` controls how far the concave curves protrude past the
///   body sides (8 compact pill, 10 expanded card).
struct NotchShape: Shape, Animatable {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(bottomRadius, shoulder) }
        set { bottomRadius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let s = shoulder
        let r = min(bottomRadius, w / 2, h - s)

        var p = Path()

        // Start at the LEFT shoulder tip — outside the frame at x = -s.
        // This point lies flat against the menu bar (y = 0).
        p.move(to: CGPoint(x: -s, y: 0))

        // Top-left concave shoulder: curve inward and downward to (0, s).
        // Control point at (0, 0) pulls the curve tight to the corner.
        p.addQuadCurve(
            to: CGPoint(x: 0, y: s),
            control: CGPoint(x: 0, y: 0)
        )

        // Left side: straight down to where bottom-left rounding begins.
        p.addLine(to: CGPoint(x: 0, y: h - r))

        // Bottom-left convex corner.
        p.addQuadCurve(
            to: CGPoint(x: r, y: h),
            control: CGPoint(x: 0, y: h)
        )

        // Bottom edge.
        p.addLine(to: CGPoint(x: w - r, y: h))

        // Bottom-right convex corner.
        p.addQuadCurve(
            to: CGPoint(x: w, y: h - r),
            control: CGPoint(x: w, y: h)
        )

        // Right side: straight up to where top concave shoulder starts.
        p.addLine(to: CGPoint(x: w, y: s))

        // Top-right concave shoulder: curve outward and upward to (w+s, 0).
        p.addQuadCurve(
            to: CGPoint(x: w + s, y: 0),
            control: CGPoint(x: w, y: 0)
        )

        // Close: SwiftUI draws a straight line from (w+s, 0) back to
        // (-s, 0). This horizontal segment is the top edge that sits flat
        // against the menu bar.
        p.closeSubpath()
        return p
    }
}
