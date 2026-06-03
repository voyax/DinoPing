import SwiftUI
import AgentPulseCore

// MARK: - Static sprite

/// Renders a `PixelSprite` as crisp filled rectangles via `Canvas`.
///
/// Each non-`.` cell becomes a `pixelSize`×`pixelSize` rect. Use integer
/// `pixelSize` (≥ 2) to avoid Retina anti-aliasing artifacts.
struct PixelSpriteView: View {
    let sprite: PixelSprite
    var pixelSize: CGFloat = 2
    var color: Color = .white

    var body: some View {
        Canvas { context, _ in
            for (y, row) in sprite.rows.enumerated() {
                for (x, char) in row.enumerated() where char != "." {
                    let rect = CGRect(
                        x: CGFloat(x) * pixelSize,
                        y: CGFloat(y) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(
            width:  CGFloat(sprite.width)  * pixelSize,
            height: CGFloat(sprite.height) * pixelSize
        )
    }
}

// MARK: - Animated sprite

/// Cycles through frames at `fps`. Uses `TimelineView` so the animation is
/// driven by SwiftUI's compositor (correct pacing, pauses when offscreen).
struct AnimatedSpriteView: View {
    let frames: [PixelSprite]
    var fps: Double = 7
    var pixelSize: CGFloat = 2
    var color: Color = .white

    var body: some View {
        if frames.count <= 1 {
            PixelSpriteView(
                sprite: frames.first ?? PixelSprite([]),
                pixelSize: pixelSize,
                color: color
            )
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / fps)) { context in
                let i = Int(context.date.timeIntervalSinceReferenceDate * fps) % frames.count
                PixelSpriteView(
                    sprite: frames[i],
                    pixelSize: pixelSize,
                    color: color
                )
            }
        }
    }
}

// MARK: - Dino convenience

/// One-call view that maps `(species, state)` → frames + fps + tint.
/// Use this everywhere in the notch UI; specific renderers shouldn't need
/// to know about sprite arrays.
struct DinoView: View {
    let species: DinoSpecies
    let state: DinoState
    var pixelSize: CGFloat = 2

    var body: some View {
        AnimatedSpriteView(
            frames: DinoSprites.frames(species, state),
            fps: DinoSprites.fps(for: state),
            pixelSize: pixelSize,
            color: tint
        )
    }

    private var tint: Color {
        switch state {
        // Dino reads ONE thing: "do I need attention?". Red = yes (ACTION
        // permission/question pending). White = no, regardless of whether
        // the agent is actively running or idle. State demotion lives in
        // the colored status text next to the dino ("4 idle" muted gray,
        // "3 working" teal, etc.) — re-encoding it in the dino color just
        // made the dormant dino unreadable, especially at pixelSize<1
        // where anti-aliasing already dilutes brightness.
        case .action:                                 Color(red: 1.0, green: 0.31, blue: 0.31)
        case .dormant, .running, .expanded:           .white
        }
    }
}

// MARK: - Previews

#Preview("All species · running") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(DinoSpecies.allCases, id: \.self) { species in
            HStack(spacing: 16) {
                Text(species.displayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 70, alignment: .leading)
                DinoView(species: species, state: .running, pixelSize: 3)
            }
        }
    }
    .padding(32)
    .background(.black)
}

private let stateLabels: [(DinoState, String)] = [
    (.dormant,  "DORMANT"),
    (.running,  "RUNNING"),
    (.expanded, "EXPANDED"),
    (.action,   "ACTION"),
]

#Preview("Rex · all states") {
    VStack(alignment: .leading, spacing: 20) {
        ForEach(stateLabels, id: \.1) { state, name in
            HStack(spacing: 16) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 90, alignment: .leading)
                DinoView(species: .rex, state: state, pixelSize: 3)
            }
        }
    }
    .padding(32)
    .background(.black)
}

#Preview("Notch · 5 sessions") {
    HStack(spacing: 4) {
        DinoView(species: .rex,   state: .running, pixelSize: 1)
        DinoView(species: .plate, state: .running, pixelSize: 1)
        DinoView(species: .tri,   state: .running, pixelSize: 1)
        DinoView(species: .sky,   state: .running, pixelSize: 1)
        DinoView(species: .long,  state: .running, pixelSize: 1)
    }
    .padding(.horizontal, 12)
    .frame(width: 220, height: 32)
    .background(.black)
}
