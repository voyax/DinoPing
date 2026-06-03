import SwiftUI

/// Status dot that breathes in time with the AgentPulse design's `apPulse`
/// keyframe — opacity 1 → 0.55 → 1, scale 1 → 0.85 → 1, ease-in-out.
/// A subtle glow `0 0 6px <color>` makes it read as "active" even before
/// the eye registers the animation.
///
/// Two callsites per spec:
/// - Session card working-state dot: 6×6, 1.6s cycle (calmer)
/// - Compact pill waiting indicator: 6×6, 1.2s cycle (slightly more urgent)
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    var duration: Double = 1.6

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            // Glow — apPulse spec says `boxShadow: '0 0 6px <status>'`.
            // SwiftUI shadow with radius ≈ 3 + low offset visually matches
            // CSS `0 0 6px` since CSS blur is roughly 2× SwiftUI radius.
            .shadow(color: color.opacity(0.85), radius: 3, x: 0, y: 0)
            // Midpoint: scale SHRINKS to 0.85 and dims to 0.55 — the dot
            // "inhales" rather than expanding outward. This is the
            // design's apPulse keyframes inverted from a naive grow-pulse.
            .scaleEffect(pulse ? 0.85 : 1.0)
            .opacity(pulse ? 0.55 : 1.0)
            .animation(
                .easeInOut(duration: duration / 2).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
