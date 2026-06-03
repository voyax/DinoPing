import SwiftUI
import AgentPulseCore

/// Tiny capsule badge that names where the agent is running. Terminal-class
/// hosts show a `>_` glyph; editor-class hosts show a `</>` glyph. The
/// label disambiguates which specific app (iTerm vs Ghostty vs Warp …).
struct HostBadge: View {
    let host: HostKind

    var body: some View {
        HStack(spacing: 4) {
            HostIcon(family: host.family)
                .foregroundStyle(.white.opacity(0.55))
            Text(host.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .padding(.vertical, 1)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// 10×10 monochrome glyph: `>_` for terminal, `</>` for editor.
struct HostIcon: View {
    let family: HostKind.Family

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let path: Path
            switch family {
            case .terminal:
                // chevron `>` + underscore `_` — terminal prompt motif
                path = Path { p in
                    // chevron at left
                    p.move(to: CGPoint(x: size.width * 0.21, y: size.height * 0.29))
                    p.addLine(to: CGPoint(x: size.width * 0.42, y: size.height * 0.50))
                    p.addLine(to: CGPoint(x: size.width * 0.21, y: size.height * 0.71))
                    // underscore at right
                    p.move(to: CGPoint(x: size.width * 0.50, y: size.height * 0.75))
                    p.addLine(to: CGPoint(x: size.width * 0.83, y: size.height * 0.75))
                }
            case .editor:
                // mirrored chevrons `</>` — angle-bracket motif
                path = Path { p in
                    p.move(to: CGPoint(x: size.width * 0.38, y: size.height * 0.29))
                    p.addLine(to: CGPoint(x: size.width * 0.17, y: size.height * 0.50))
                    p.addLine(to: CGPoint(x: size.width * 0.38, y: size.height * 0.71))
                    p.move(to: CGPoint(x: size.width * 0.62, y: size.height * 0.29))
                    p.addLine(to: CGPoint(x: size.width * 0.83, y: size.height * 0.50))
                    p.addLine(to: CGPoint(x: size.width * 0.62, y: size.height * 0.71))
                }
            }
            context.stroke(path, with: .color(.primary), style: stroke)
        }
        .frame(width: 10, height: 10)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(HostKind.allCases, id: \.self) { host in
            HostBadge(host: host)
        }
    }
    .padding(24)
    .background(Color(red: 0.04, green: 0.04, blue: 0.05))
}
