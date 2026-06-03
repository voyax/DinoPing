import SwiftUI
import AgentPulseCore

/// 16×16 rounded tile filled with the agent's brand color, displaying the
/// agent's 2-character monogram in black monospace 9pt / 700 weight.
/// Sits at the leading edge of every SessionCard's Row 1.
struct AgentMonogramTile: View {
    let agent: AgentKind
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(agent.tintColor)
            Text(agent.monogram)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.2)
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
        .help(agent.displayName)
    }
}

#Preview {
    VStack(spacing: 6) {
        ForEach(AgentKind.allCases, id: \.self) { agent in
            HStack(spacing: 10) {
                AgentMonogramTile(agent: agent)
                Text(agent.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
    .padding(20)
    .background(Color(red: 0.04, green: 0.04, blue: 0.05))
}
