import SwiftUI

/// AgentPulse design tokens — colors only. The names + hex values come
/// straight from `design_handoff_agentpulse/README.md > Design Tokens > Colors`.
/// Access via `Color.ap.<token>` so every callsite is grepable and the
/// palette can be re-tuned in one place without chasing literal hex strings.
extension Color {
    enum ap {
        // MARK: - Backgrounds
        /// Expanded card gradient top.
        static let bgCardTop = Color(red: 0.039, green: 0.039, blue: 0.047)  // #0a0a0c
        /// Expanded card gradient bottom.
        static let bgCardBottom = Color(red: 0.078, green: 0.078, blue: 0.086) // #141416
        /// Compact pill / dormant notch.
        static let bgPill = Color.black

        // MARK: - Foreground (text)
        /// Primary text.
        static let fg = Color(red: 0.910, green: 0.910, blue: 0.918)  // #e8e8ea
        /// Secondary text (prompt body, summary).
        static let fgMuted = Color.white.opacity(0.78)
        /// Tertiary (branch / file path).
        static let fgDim = Color.white.opacity(0.45)
        /// Meta row text.
        static let fgFaint = Color.white.opacity(0.38)

        // MARK: - Strokes / dividers
        static let stroke = Color.white.opacity(0.05)
        static let strokeStrong = Color.white.opacity(0.08)
        static let divider = Color.white.opacity(0.06)

        // MARK: - Row backgrounds
        static let rowBg = Color.white.opacity(0.045)
        /// Orange-tinted background for waiting (needs-you) session rows.
        static let rowBgWaiting = Color(red: 1.000, green: 0.624, blue: 0.039).opacity(0.10) // #ff9f0a @ 10%
        static let rowStrokeWaiting = Color(red: 1.000, green: 0.624, blue: 0.039).opacity(0.45)

        static let badgeBg = Color.white.opacity(0.07)

        // MARK: - Accent (action state)
        /// Default action accent — orange.
        static let accentDefault = Color(red: 1.000, green: 0.624, blue: 0.039) // #ff9f0a

        // MARK: - Status palette (Apple system colors)
        static let statusWorking = Color(red: 0.039, green: 0.518, blue: 1.000) // #0a84ff
        static let statusWaiting = Color(red: 1.000, green: 0.624, blue: 0.039) // #ff9f0a
        static let statusDone    = Color(red: 0.188, green: 0.820, blue: 0.345) // #30d158
        static let statusError   = Color(red: 1.000, green: 0.271, blue: 0.227) // #ff453a

        // MARK: - Special-purpose text accents
        /// Waiting headline / prompt title.
        static let textOrange = Color(red: 1.000, green: 0.702, blue: 0.251)    // #ffb340
        /// "Working" label inside the compact pill.
        static let textTeal   = Color(red: 0.369, green: 0.918, blue: 0.831)    // #5eead4
        /// Soft red used for error count in the pill (less alarming than full #ff453a).
        static let textRed    = Color(red: 1.000, green: 0.412, blue: 0.380)    // #ff6961

        // MARK: - Diff stats
        static let diffAdd = Color(red: 0.188, green: 0.820, blue: 0.345)       // #30d158
        static let diffRemove = Color(red: 1.000, green: 0.271, blue: 0.227)    // #ff453a
    }
}
